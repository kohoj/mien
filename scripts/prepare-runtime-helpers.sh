#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
manifest="$project_root/Config/runtime-manifest.json"
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
for command in git npm bun swift lipo jq shasum; do
  command -v "$command" >/dev/null || { print -u2 "missing build tool: $command"; exit 69; }
done

expected_bun="$(jq -r '.buildToolchain.bun' "$manifest")"
[[ "$(bun --version)" == "$expected_bun" ]] || {
  print -u2 "Bun version mismatch: expected $expected_bun, got $(bun --version)"
  exit 65
}

manifest_digest="$(shasum -a 256 "$manifest" | awk '{print $1}')"
script_digest="$(shasum -a 256 "${0:A}" | awk '{print $1}')"
build_inputs_digest="$(print -r -- "$manifest_digest:$script_digest" | shasum -a 256 | awk '{print $1}')"
manifest_stamp="$output_directory/runtime-manifest.sha256"
build_inputs_stamp="$output_directory/runtime-build-inputs.sha256"
if [[ -x "$output_directory/codex-acp" \
  && -x "$output_directory/codex" \
  && -x "$output_directory/longview" \
  && -f "$manifest_stamp" \
  && -f "$build_inputs_stamp" \
  && "$(<"$manifest_stamp")" == "$manifest_digest" \
  && "$(<"$build_inputs_stamp")" == "$build_inputs_digest" ]]; then
  for helper in codex-acp codex longview; do
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

codex_version="$(jq -r '.codex.version' "$manifest")"
codex_packages="$workspace/codex-packages"
mkdir -p "$codex_packages/arm64" "$codex_packages/x86_64"
for architecture in arm64 x86_64; do
  platform="$architecture"
  [[ "$architecture" == "x86_64" ]] && platform="x64"
  package_root="$codex_packages/$architecture"
  (
    cd "$package_root"
    archive="$(npm pack "@openai/codex@${codex_version}-darwin-${platform}" --silent)"
    tar -xzf "$archive"
  )
done
codex_arm="$codex_packages/arm64/package/vendor/aarch64-apple-darwin/bin/codex"
codex_x64="$codex_packages/x86_64/package/vendor/x86_64-apple-darwin/bin/codex"
[[ -x "$codex_arm" && -x "$codex_x64" ]] || { print -u2 "Codex package layout changed"; exit 65; }
lipo -create "$codex_arm" "$codex_x64" -output "$staging/codex"

codex_repository="$(jq -r '.codex.repository' "$manifest")"
codex_commit="$(jq -r '.codex.commit' "$manifest")"
codex_source="$workspace/codex-source"
git clone --quiet --filter=blob:none --no-checkout "$codex_repository" "$codex_source"
git -C "$codex_source" sparse-checkout set LICENSE NOTICE
git -C "$codex_source" checkout --quiet "$codex_commit"
[[ "$(git -C "$codex_source" rev-parse HEAD)" == "$codex_commit" ]] || exit 65

acp_repository="$(jq -r '.codexACP.repository' "$manifest")"
acp_commit="$(jq -r '.codexACP.commit' "$manifest")"
acp_source="$workspace/codex-acp"
git clone --quiet "$acp_repository" "$acp_source"
git -C "$acp_source" checkout --quiet "$acp_commit"
[[ "$(git -C "$acp_source" rev-parse HEAD)" == "$acp_commit" ]] || exit 65
(
  cd "$acp_source"
  npm ci --ignore-scripts
  npm audit --omit=dev --audit-level=moderate
  bun run bundle:darwin-arm64
  bun run bundle:darwin-x64
)
lipo -create \
  "$acp_source/dist/bin/codex-acp-arm64-darwin" \
  "$acp_source/dist/bin/codex-acp-x64-darwin" \
  -output "$staging/codex-acp"

longview_repository="$(jq -r '.longview.repository' "$manifest")"
longview_commit="$(jq -r '.longview.commit' "$manifest")"
longview_source="$workspace/longview"
git clone --quiet "$longview_repository" "$longview_source"
git -C "$longview_source" checkout --quiet "$longview_commit"
[[ "$(git -C "$longview_source" rev-parse HEAD)" == "$longview_commit" ]] || exit 65
for architecture in arm64 x86_64; do
  swift build \
    --package-path "$longview_source" \
    --scratch-path "$workspace/longview-build-$architecture" \
    -c release \
    --arch "$architecture" \
    --product longview
done
lipo -create \
  "$workspace/longview-build-arm64/arm64-apple-macosx/release/longview" \
  "$workspace/longview-build-x86_64/x86_64-apple-macosx/release/longview" \
  -output "$staging/longview"

mkdir -p "$staging/licenses"
cp "$codex_source/LICENSE" "$staging/licenses/OpenAI-Codex-Apache-2.0.txt"
cp "$codex_source/NOTICE" "$staging/licenses/OpenAI-Codex-NOTICE.txt"
cp "$acp_source/LICENSE" "$staging/licenses/Codex-ACP-Apache-2.0.txt"
cp "$longview_source/LICENSE" "$staging/licenses/Longview-MIT.txt"

chmod 755 "$staging/"*
for helper in codex-acp codex longview; do
  architectures="$(lipo -archs "$staging/$helper")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    print -u2 "missing universal architecture: $helper"
    exit 65
  }
done
actual_codex_version="$("$staging/codex" --version)"
actual_codex_version="${actual_codex_version#codex-cli }"
[[ "$actual_codex_version" == "$codex_version" ]] || exit 65

jq -n \
  --arg manifestSHA256 "$manifest_digest" \
  --arg buildScriptSHA256 "$script_digest" \
  --arg buildInputsSHA256 "$build_inputs_digest" \
  --arg codexSHA256 "$(shasum -a 256 "$staging/codex" | awk '{print $1}')" \
  --arg codexACPSHA256 "$(shasum -a 256 "$staging/codex-acp" | awk '{print $1}')" \
  --arg longviewSHA256 "$(shasum -a 256 "$staging/longview" | awk '{print $1}')" \
  '{
    schemaVersion: 1,
    runtimeManifestSHA256: $manifestSHA256,
    buildScriptSHA256: $buildScriptSHA256,
    buildInputsSHA256: $buildInputsSHA256,
    architectures: ["arm64", "x86_64"],
    helpers: {
      codex: {sha256: $codexSHA256},
      codexACP: {sha256: $codexACPSHA256},
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
