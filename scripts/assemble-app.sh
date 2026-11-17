#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
output_path="$project_root/.build/distribution/Mien.app"
signing_identity="-"
pi_agent_path=""
longview_path=""
architectures="arm64,x86_64"

usage() {
  print -u2 "usage: $0 [--pi-agent PATH --longview PATH] [--output APP] [--identity ID] [--architectures arm64|arm64,x86_64]"
}

while (( $# > 0 )); do
  case "$1" in
    --pi-agent) pi_agent_path="$2"; shift 2 ;;
    --longview) longview_path="$2"; shift 2 ;;
    --output) output_path="$2"; shift 2 ;;
    --identity) signing_identity="$2"; shift 2 ;;
    --architectures) architectures="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [[ -z "$pi_agent_path" && -z "$longview_path" ]]; then
  "$project_root/scripts/prepare-runtime-helpers.sh"
  runtime_directory="$project_root/.build/runtime-helpers/universal"
  pi_agent_path="$runtime_directory/mien-pi-agent"
  longview_path="$runtime_directory/longview"
elif [[ -z "$pi_agent_path" || -z "$longview_path" ]]; then
  print -u2 "provide both helper paths or none"
  exit 64
fi

for helper in "$pi_agent_path" "$longview_path"; do
  [[ -x "$helper" && "${helper:A}" == /* ]] || { print -u2 "helper must be an absolute executable: $helper"; exit 66; }
done
[[ "$output_path" == *.app ]] || { print -u2 "output must end in .app"; exit 64; }
[[ "$output_path" == /* ]] || output_path="$project_root/$output_path"

"$project_root/scripts/build-result-renderer.sh" --check

expected_pi_version="$(plutil -extract piAgent.version raw "$project_root/Config/runtime-manifest.json")"
actual_pi_version="$($pi_agent_path --version)"
[[ "$actual_pi_version" == "mien-pi-agent $expected_pi_version" ]] || {
  print -u2 "Pi Agent version mismatch: expected $expected_pi_version, got $actual_pi_version"
  exit 65
}

required_architectures=(${(s:,:)architectures})
for helper in "$pi_agent_path" "$longview_path"; do
  helper_architectures="$(lipo -archs "$helper")"
  for architecture in "${required_architectures[@]}"; do
    [[ " $helper_architectures " == *" $architecture "* ]] || {
      print -u2 "$helper does not contain required architecture: $architecture"
      exit 65
    }
  done
done

build_root="$project_root/.build/app-assembly"
host_binary="$build_root/Mien"
mkdir -p "$build_root"

case "$architectures" in
  arm64|x86_64|arm64,x86_64|x86_64,arm64) ;;
  *) print -u2 "unsupported architecture set: $architectures"; exit 64 ;;
esac
host_binaries=()
for architecture in "${required_architectures[@]}"; do
  swift build --package-path "$project_root" --scratch-path "$build_root/$architecture" -c release --arch "$architecture" --product mien
  binary_directory="$(swift build --package-path "$project_root" --scratch-path "$build_root/$architecture" -c release --arch "$architecture" --show-bin-path)"
  host_binaries+=("$binary_directory/mien")
done
if (( ${#host_binaries} == 1 )); then
  cp "${host_binaries[1]}" "$host_binary"
else
  lipo -create "${host_binaries[@]}" -output "$host_binary"
fi

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/mien-app.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
app="$staging_root/Mien.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$project_root/Config/Info.plist" "$app/Contents/Info.plist"
cp "$project_root/Config/runtime-manifest.json" "$app/Contents/Resources/runtime-manifest.json"
"$project_root/scripts/build-app-icon.sh" \
  --output "$app/Contents/Resources/Mien.icns"
[[ -d "${pi_agent_path:h}/licenses" ]] || {
  print -u2 "runtime helper directory is missing third-party licenses"
  exit 65
}
cp -R "${pi_agent_path:h}/licenses" "$app/Contents/Resources/ThirdPartyLicenses"
cp -R \
  "$project_root/Sources/InteractionShell/Resources/ResultRenderer" \
  "$app/Contents/Resources/ResultRenderer"
"$project_root/scripts/result-renderer-manifest.mjs" \
  --metafile "$project_root/Web/ResultRenderer/dist/renderer.meta.json" \
  --lockfile "$project_root/Web/ResultRenderer/package-lock.json" \
  --output "$app/Contents/Resources/result-renderer-components.json" \
  --licenses "$app/Contents/Resources/ThirdPartyLicenses/ResultRenderer"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$host_binary" "$app/Contents/MacOS/Mien"
cp "$pi_agent_path" "$app/Contents/Helpers/mien-pi-agent"
cp "$longview_path" "$app/Contents/Helpers/longview"
chmod 755 "$app/Contents/MacOS/Mien" "$app/Contents/Helpers/"*

timestamp_args=(--timestamp)
[[ "$signing_identity" == "-" ]] && timestamp_args=(--timestamp=none)
for helper in mien-pi-agent longview; do
  codesign --force --sign "$signing_identity" --options runtime "${timestamp_args[@]}" "$app/Contents/Helpers/$helper"
done

pi_agent_digest="$(shasum -a 256 "$app/Contents/Helpers/mien-pi-agent" | awk '{print $1}')"
longview_digest="$(shasum -a 256 "$app/Contents/Helpers/longview" | awk '{print $1}')"
{
  print '{'
  print "  \"piAgent\": \"$pi_agent_digest\","
  print "  \"longview\": \"$longview_digest\""
  print '}'
} > "$app/Contents/Resources/runtime-digests.json"
"$project_root/scripts/generate-sbom.sh" \
  --manifest "$app/Contents/Resources/runtime-manifest.json" \
  --digests "$app/Contents/Resources/runtime-digests.json" \
  --renderer-components "$app/Contents/Resources/result-renderer-components.json" \
  --output "$app/Contents/Resources/mien.cdx.json"

codesign --force --sign "$signing_identity" --options runtime "${timestamp_args[@]}" \
  --entitlements "$project_root/Config/Mien.entitlements" "$app"
"$project_root/scripts/verify-app-bundle.sh" "$app"

mkdir -p "${output_path:h}"
rm -rf "$output_path"
ditto "$app" "$output_path"
print "$output_path"
