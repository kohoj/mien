#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_path=""
keychain_profile=""
output_path=""

usage() {
  print -u2 "usage: $0 --app /absolute/path/Mien.app --keychain-profile PROFILE [--output ZIP]"
}

while (( $# > 0 )); do
  case "$1" in
    --app) app_path="$2"; shift 2 ;;
    --keychain-profile) keychain_profile="$2"; shift 2 ;;
    --output) output_path="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ -d "$app_path" && "$app_path" == /*.app ]] || { usage; exit 64; }
[[ -n "$keychain_profile" ]] || { usage; exit 64; }
[[ -n "$output_path" ]] || output_path="$project_root/.build/distribution/Mien.zip"
[[ "$output_path" == /*.zip ]] || { print -u2 "output must be an absolute .zip path"; exit 64; }

"$project_root/scripts/verify-app-bundle.sh" "$app_path" --require-developer-id

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/mien-notary.XXXXXX")"
staging_archive="$staging_root/Mien.zip"
trap 'rm -rf "$staging_root"' EXIT
/usr/bin/ditto -c -k --keepParent "$app_path" "$staging_archive"
/usr/bin/xcrun notarytool submit "$staging_archive" \
  --keychain-profile "$keychain_profile" \
  --wait
/usr/bin/xcrun stapler staple "$app_path"
/usr/bin/xcrun stapler validate "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
"$project_root/scripts/verify-app-bundle.sh" "$app_path" --require-developer-id

mkdir -p "${output_path:h}"
/usr/bin/ditto -c -k --keepParent "$app_path" "$output_path"
(
  cd "${output_path:h}"
  /usr/bin/shasum -a 256 "${output_path:t}" > "${output_path:t}.sha256"
)
print "$output_path"
print "$output_path.sha256"
