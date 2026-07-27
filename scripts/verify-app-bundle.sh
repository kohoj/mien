#!/bin/zsh
set -euo pipefail

app_path="${1:-}"
release_required="${2:-}"
[[ -d "$app_path" && "$app_path" == /*.app ]] || {
  print -u2 "usage: $0 /absolute/path/Mien.app [--require-developer-id]"
  exit 64
}
[[ -z "$release_required" || "$release_required" == "--require-developer-id" ]] || exit 64

for path in \
  "$app_path/Contents/MacOS/Mien" \
  "$app_path/Contents/Helpers/codex-acp" \
  "$app_path/Contents/Helpers/codex" \
  "$app_path/Contents/Helpers/longview" \
  "$app_path/Contents/Resources/Mien.icns" \
  "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" \
  "$app_path/Contents/Resources/ThirdPartyLicenses/OpenAI-Codex-Apache-2.0.txt" \
  "$app_path/Contents/Resources/ThirdPartyLicenses/OpenAI-Codex-NOTICE.txt" \
  "$app_path/Contents/Resources/ThirdPartyLicenses/Codex-ACP-Apache-2.0.txt" \
  "$app_path/Contents/Resources/ThirdPartyLicenses/Longview-MIT.txt" \
  "$app_path/Contents/Resources/mien.cdx.json" \
  "$app_path/Contents/Resources/runtime-digests.json"; do
  [[ -e "$path" ]] || { print -u2 "missing bundle member: $path"; exit 66; }
done

/usr/bin/jq -e '
  .bomFormat == "CycloneDX" and
  .specVersion == "1.5" and
  (.components | length == 3)
' "$app_path/Contents/Resources/mien.cdx.json" >/dev/null

/usr/bin/plutil -lint "$app_path/Contents/Info.plist" >/dev/null
for key in codexACP codex longview; do
  digest="$(/usr/bin/plutil -extract "$key" raw "$app_path/Contents/Resources/runtime-digests.json")"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || { print -u2 "invalid runtime digest: $key"; exit 65; }
  case "$key" in
    codexACP) helper="codex-acp" ;;
    codex) helper="codex" ;;
    longview) helper="longview" ;;
  esac
  actual="$(/usr/bin/shasum -a 256 "$app_path/Contents/Helpers/$helper" | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$digest" ]] || { print -u2 "runtime digest mismatch: $helper"; exit 65; }
done

host_architectures=(${(z)$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/Mien")})
for helper in codex-acp codex longview; do
  helper_architectures="$(/usr/bin/lipo -archs "$app_path/Contents/Helpers/$helper")"
  for architecture in "${host_architectures[@]}"; do
    [[ " $helper_architectures " == *" $architecture "* ]] || {
      print -u2 "$helper does not contain required architecture: $architecture"
      exit 65
    }
  done
  /usr/bin/codesign --verify --strict --verbose=2 "$app_path/Contents/Helpers/$helper"
done
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" = \
  "io.github.kohoj.mien"
test "$(/usr/bin/plutil -extract CFBundleExecutable raw "$app_path/Contents/Info.plist")" = \
  "Mien"
test "$(/usr/bin/plutil -extract CFBundleIconFile raw "$app_path/Contents/Info.plist")" = \
  "Mien.icns"

if [[ "$release_required" == "--require-developer-id" ]]; then
  signature="$(/usr/bin/codesign -dvv "$app_path" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application:"* ]] || {
    print -u2 "Developer ID Application signature required"
    exit 65
  }
  team_identifier="$(print -r -- "$signature" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] || {
    print -u2 "signed release has no TeamIdentifier"
    exit 65
  }
fi
print "app bundle verified"
