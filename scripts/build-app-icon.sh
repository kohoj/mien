#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_png="$project_root/Resources/AppIcon/mien-1024.png"
output_path=""

usage() {
  print -u2 "usage: $0 --output /absolute/path/Mien.icns"
}

while (( $# > 0 )); do
  case "$1" in
    --output) output_path="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ -f "$source_png" ]] || { print -u2 "missing app icon source"; exit 66; }
[[ "$output_path" == /*.icns ]] || { usage; exit 64; }

workspace="$(mktemp -d "${TMPDIR:-/tmp}/mien-icon.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
iconset="$workspace/Mien.iconset"
mkdir -p "$iconset" "${output_path:h}"

for specification in \
  "16:icon_16x16.png" \
  "32:icon_16x16@2x.png" \
  "32:icon_32x32.png" \
  "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" \
  "256:icon_128x128@2x.png" \
  "256:icon_256x256.png" \
  "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" \
  "1024:icon_512x512@2x.png"; do
  size="${specification%%:*}"
  name="${specification#*:}"
  /usr/bin/sips -z "$size" "$size" "$source_png" --out "$iconset/$name" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset" -o "$output_path"
test -s "$output_path"
