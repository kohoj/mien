#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
manifest="$project_root/Config/runtime-manifest.json"
agent_directory="$project_root/Runtime/PiAgent"
agent_source="$agent_directory/main.ts"
agent_protocol_source="$agent_directory/turn-protocol.ts"
agent_catalog_source="$agent_directory/codex-models.ts"
agent_memory_source="$agent_directory/conversation-memory.ts"
agent_package="$agent_directory/package.json"
agent_lock="$agent_directory/package-lock.json"
output_directory="$project_root/.build/runtime-helpers/universal"

usage() {
  print -u2 "usage: $0 [--output DIRECTORY]"
}

while (( $# > 0 )); do
  case "$1" in
    --output) output_directory="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ "$output_directory" == /* ]] || output_directory="$project_root/$output_directory"
for command in git npm bun swift lipo jq shasum codesign; do
  command -v "$command" >/dev/null || { print -u2 "missing build tool: $command"; exit 69; }
done

expected_bun="$(jq -r '.buildToolchain.bun' "$manifest")"
[[ "$(bun --version)" == "$expected_bun" ]] || {
  print -u2 "Bun version mismatch: expected $expected_bun, got $(bun --version)"
  exit 65
}

manifest_digest="$(shasum -a 256 "$manifest" | awk '{print $1}')"
script_digest="$(shasum -a 256 "${0:A}" | awk '{print $1}')"
agent_source_digest="$(shasum -a 256 "$agent_source" | awk '{print $1}')"
agent_protocol_source_digest="$(shasum -a 256 "$agent_protocol_source" | awk '{print $1}')"
agent_catalog_source_digest="$(shasum -a 256 "$agent_catalog_source" | awk '{print $1}')"
agent_memory_source_digest="$(shasum -a 256 "$agent_memory_source" | awk '{print $1}')"
agent_package_digest="$(shasum -a 256 "$agent_package" | awk '{print $1}')"
agent_lock_digest="$(shasum -a 256 "$agent_lock" | awk '{print $1}')"
build_inputs_digest="$(print -r -- "$manifest_digest:$script_digest:$agent_source_digest:$agent_protocol_source_digest:$agent_catalog_source_digest:$agent_memory_source_digest:$agent_package_digest:$agent_lock_digest" | shasum -a 256 | awk '{print $1}')"
manifest_stamp="$output_directory/runtime-manifest.sha256"
build_inputs_stamp="$output_directory/runtime-build-inputs.sha256"
if [[ -x "$output_directory/mien-pi-agent" \
  && -x "$output_directory/longview" \
  && -f "$manifest_stamp" \
  && -f "$build_inputs_stamp" \
  && "$(<"$manifest_stamp")" == "$manifest_digest" \
  && "$(<"$build_inputs_stamp")" == "$build_inputs_digest" ]]; then
  for helper in mien-pi-agent longview; do
    architectures="$(lipo -archs "$output_directory/$helper")"
    [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || exit 65
  done
  print "$output_directory"
  exit 0
fi

workspace="$(mktemp -d "${TMPDIR:-/tmp}/mien-runtime.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
staging="$workspace/output"
mkdir -p "$staging"

pi_repository="$(jq -r '.piAgent.repository' "$manifest")"
pi_commit="$(jq -r '.piAgent.commit' "$manifest")"
pi_version="$(jq -r '.piAgent.version' "$manifest")"
pi_package_integrity="$(jq -r '.piAgent.packageIntegrity' "$manifest")"
pi_source="$workspace/pi"
git clone --quiet "$pi_repository" "$pi_source"
git -C "$pi_source" checkout --quiet "$pi_commit"
[[ "$(git -C "$pi_source" rev-parse HEAD)" == "$pi_commit" ]] || exit 65
[[ "$(jq -r '.version' "$pi_source/packages/coding-agent/package.json")" == "$pi_version" ]] || exit 65

agent_build="$workspace/mien-agent-runtime"
mkdir -p "$agent_build"
cp "$agent_source" "$agent_protocol_source" "$agent_catalog_source" "$agent_memory_source" "$agent_package" "$agent_lock" "$agent_build/"
(
  cd "$agent_build"
  locked_integrity="$(jq -r '.packages["node_modules/@earendil-works/pi-coding-agent"].integrity' package-lock.json)"
  [[ "$locked_integrity" == "$pi_package_integrity" ]] || exit 65
  npm ci --ignore-scripts --no-audit
  [[ "$(jq -r '.version' node_modules/@earendil-works/pi-coding-agent/package.json)" == "$pi_version" ]] || exit 65

  # Pi 0.82.1 publishes an npm shrinkwrap with brace-expansion 5.0.7. Replace
  # that exact transitive copy with the pinned 5.0.8 security fix before Bun
  # resolves the dependency graph. Mien does not expose Pi's glob tools, but
  # the packaged runtime must not retain known-vulnerable executable code.
  vulnerable="node_modules/@earendil-works/pi-coding-agent/node_modules/brace-expansion"
  [[ "$(jq -r '.version' "$vulnerable/package.json")" == "5.0.7" ]] || exit 65
  mv "$vulnerable" "$workspace/brace-expansion-5.0.7"
  ditto node_modules/brace-expansion "$vulnerable"
  [[ "$(jq -r '.version' "$vulnerable/package.json")" == "5.0.8" ]] || exit 65

  bun build --compile --target=bun-darwin-arm64 main.ts \
    --outfile "$workspace/mien-pi-agent-arm64"
  bun build --compile --target=bun-darwin-x64 main.ts \
    --outfile "$workspace/mien-pi-agent-x86_64"
)
lipo -create \
  "$workspace/mien-pi-agent-arm64" \
  "$workspace/mien-pi-agent-x86_64" \
  -output "$staging/mien-pi-agent"
# Bun's embedded linker signature is invalid after universal assembly. Sign
# before executing the version probe; the app assembler signs the final copy
# again with its selected identity and hardened-runtime options.
codesign --force --sign - --timestamp=none "$staging/mien-pi-agent"
codesign --verify --strict "$staging/mien-pi-agent"
actual_pi_version="$("$staging/mien-pi-agent" --version)"
[[ "$actual_pi_version" == "mien-pi-agent $pi_version" ]] || exit 65

longview_repository="$(jq -r '.longview.repository' "$manifest")"
longview_commit="$(jq -r '.longview.commit' "$manifest")"
longview_source="$workspace/longview"
git clone --quiet "$longview_repository" "$longview_source"
git -C "$longview_source" checkout --quiet "$longview_commit"
[[ "$(git -C "$longview_source" rev-parse HEAD)" == "$longview_commit" ]] || exit 65
longview_binaries=()
for architecture in arm64 x86_64; do
  swift build \
    --package-path "$longview_source" \
    --scratch-path "$workspace/longview-build-$architecture" \
    -c release \
    --arch "$architecture" \
    --product longview
  binary_directory="$(swift build \
    --package-path "$longview_source" \
    --scratch-path "$workspace/longview-build-$architecture" \
    -c release --arch "$architecture" --show-bin-path)"
  longview_binaries+=("$binary_directory/longview")
done
lipo -create "${longview_binaries[@]}" -output "$staging/longview"

mkdir -p "$staging/licenses"
cp "$pi_source/LICENSE" "$staging/licenses/Pi-MIT.txt"
cp "$longview_source/LICENSE" "$staging/licenses/Longview-MIT.txt"

chmod 755 "$staging/"*
for helper in mien-pi-agent longview; do
  architectures="$(lipo -archs "$staging/$helper")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    print -u2 "missing universal architecture: $helper"
    exit 65
  }
done

jq -n \
  --arg manifestSHA256 "$manifest_digest" \
  --arg buildScriptSHA256 "$script_digest" \
  --arg agentSourceSHA256 "$agent_source_digest" \
  --arg agentProtocolSourceSHA256 "$agent_protocol_source_digest" \
  --arg agentCatalogSourceSHA256 "$agent_catalog_source_digest" \
  --arg agentPackageSHA256 "$agent_package_digest" \
  --arg agentPackageLockSHA256 "$agent_lock_digest" \
  --arg buildInputsSHA256 "$build_inputs_digest" \
  --arg piAgentSHA256 "$(shasum -a 256 "$staging/mien-pi-agent" | awk '{print $1}')" \
  --arg longviewSHA256 "$(shasum -a 256 "$staging/longview" | awk '{print $1}')" \
  '{
    schemaVersion: 1,
    runtimeManifestSHA256: $manifestSHA256,
    buildScriptSHA256: $buildScriptSHA256,
    agentSourceSHA256: $agentSourceSHA256,
    agentProtocolSourceSHA256: $agentProtocolSourceSHA256,
    agentCatalogSourceSHA256: $agentCatalogSourceSHA256,
    agentPackageSHA256: $agentPackageSHA256,
    agentPackageLockSHA256: $agentPackageLockSHA256,
    buildInputsSHA256: $buildInputsSHA256,
    architectures: ["arm64", "x86_64"],
    helpers: {
      piAgent: {sha256: $piAgentSHA256},
      longview: {sha256: $longviewSHA256}
    },
    licensesIncluded: true
  }' > "$staging/provenance.json"
print -r -- "$manifest_digest" > "$staging/runtime-manifest.sha256"
print -r -- "$build_inputs_digest" > "$staging/runtime-build-inputs.sha256"

mkdir -p "${output_directory:h}"
if [[ -e "$output_directory" ]]; then
  previous="$workspace/previous-output"
  mv "$output_directory" "$previous"
fi
mv "$staging" "$output_directory"
print "$output_directory"
