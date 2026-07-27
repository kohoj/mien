#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
output_path="$project_root/.build/distribution/Mien.app"
signing_identity="-"
codex_acp_path=""
codex_path=""
longview_path=""
architectures="arm64,x86_64"

usage() {
  print -u2 "usage: $0 [--codex-acp PATH --codex PATH --longview PATH] [--output APP] [--identity ID] [--architectures arm64|arm64,x86_64]"
}

while (( $# > 0 )); do
  case "$1" in
    --codex-acp) codex_acp_path="$2"; shift 2 ;;
    --codex) codex_path="$2"; shift 2 ;;
    --longview) longview_path="$2"; shift 2 ;;
    --output) output_path="$2"; shift 2 ;;
    --identity) signing_identity="$2"; shift 2 ;;
    --architectures) architectures="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

if [[ -z "$codex_acp_path" && -z "$codex_path" && -z "$longview_path" ]]; then
  "$project_root/scripts/prepare-runtime-helpers.sh"
  runtime_directory="$project_root/.build/runtime-helpers/universal"
  codex_acp_path="$runtime_directory/codex-acp"
  codex_path="$runtime_directory/codex"
  longview_path="$runtime_directory/longview"
elif [[ -z "$codex_acp_path" || -z "$codex_path" || -z "$longview_path" ]]; then
  print -u2 "provide all three helper paths or none"
  exit 64
fi

for helper in "$codex_acp_path" "$codex_path" "$longview_path"; do
  [[ -x "$helper" && "${helper:A}" == /* ]] || { print -u2 "helper must be an absolute executable: $helper"; exit 66; }
done
[[ "$output_path" == *.app ]] || { print -u2 "output must end in .app"; exit 64; }
[[ "$output_path" == /* ]] || output_path="$project_root/$output_path"

expected_codex_version="$(plutil -extract codex.version raw "$project_root/Config/runtime-manifest.json")"
actual_codex_version="$($codex_path --version)"
actual_codex_version="${actual_codex_version#codex-cli }"
[[ "$actual_codex_version" == "$expected_codex_version" ]] || {
  print -u2 "Codex version mismatch: expected $expected_codex_version, got $actual_codex_version"
  exit 65
}

required_architectures=(${(s:,:)architectures})
for helper in "$codex_acp_path" "$codex_path" "$longview_path"; do
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
  arm64|x86_64)
    swift build --package-path "$project_root" --scratch-path "$build_root/$architectures" -c release --arch "$architectures" --product mien
    cp "$build_root/$architectures/$architectures-apple-macosx/release/mien" "$host_binary"
    ;;
  arm64,x86_64|x86_64,arm64)
    for architecture in arm64 x86_64; do
      swift build --package-path "$project_root" --scratch-path "$build_root/$architecture" -c release --arch "$architecture" --product mien
    done
    lipo -create \
      "$build_root/arm64/arm64-apple-macosx/release/mien" \
      "$build_root/x86_64/x86_64-apple-macosx/release/mien" \
      -output "$host_binary"
    ;;
  *) print -u2 "unsupported architecture set: $architectures"; exit 64 ;;
esac

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/mien-app.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
app="$staging_root/Mien.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$project_root/Config/Info.plist" "$app/Contents/Info.plist"
cp "$project_root/Config/runtime-manifest.json" "$app/Contents/Resources/runtime-manifest.json"
"$project_root/scripts/build-app-icon.sh" \
  --output "$app/Contents/Resources/Mien.icns"
[[ -d "${codex_path:h}/licenses" ]] || {
  print -u2 "runtime helper directory is missing third-party licenses"
  exit 65
}
cp -R "${codex_path:h}/licenses" "$app/Contents/Resources/ThirdPartyLicenses"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$host_binary" "$app/Contents/MacOS/Mien"
cp "$codex_acp_path" "$app/Contents/Helpers/codex-acp"
cp "$codex_path" "$app/Contents/Helpers/codex"
cp "$longview_path" "$app/Contents/Helpers/longview"
chmod 755 "$app/Contents/MacOS/Mien" "$app/Contents/Helpers/"*

timestamp_args=(--timestamp)
[[ "$signing_identity" == "-" ]] && timestamp_args=(--timestamp=none)
for helper in codex-acp codex longview; do
  codesign --force --sign "$signing_identity" --options runtime "${timestamp_args[@]}" "$app/Contents/Helpers/$helper"
done

codex_acp_digest="$(shasum -a 256 "$app/Contents/Helpers/codex-acp" | awk '{print $1}')"
codex_digest="$(shasum -a 256 "$app/Contents/Helpers/codex" | awk '{print $1}')"
longview_digest="$(shasum -a 256 "$app/Contents/Helpers/longview" | awk '{print $1}')"
{
  print '{'
  print "  \"codexACP\": \"$codex_acp_digest\","
  print "  \"codex\": \"$codex_digest\","
  print "  \"longview\": \"$longview_digest\""
  print '}'
} > "$app/Contents/Resources/runtime-digests.json"
"$project_root/scripts/generate-sbom.sh" \
  --manifest "$app/Contents/Resources/runtime-manifest.json" \
  --digests "$app/Contents/Resources/runtime-digests.json" \
  --output "$app/Contents/Resources/mien.cdx.json"

codesign --force --sign "$signing_identity" --options runtime "${timestamp_args[@]}" \
  --entitlements "$project_root/Config/Mien.entitlements" "$app"
"$project_root/scripts/verify-app-bundle.sh" "$app"

mkdir -p "${output_path:h}"
rm -rf "$output_path"
ditto "$app" "$output_path"
print "$output_path"
