#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
web_root="$project_root/Web/ResultRenderer"
resource_root="$project_root/Sources/InteractionShell/Resources/ResultRenderer"
check_only=false

usage() {
  print -u2 "usage: $0 [--check]"
}

while (( $# > 0 )); do
  case "$1" in
    --check) check_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

command -v npm >/dev/null || { print -u2 "npm is required to build the result renderer"; exit 69; }
command -v bun >/dev/null || { print -u2 "bun is required to build the result renderer"; exit 69; }
[[ "$(bun --version)" == "1.3.13" ]] || {
  print -u2 "result renderer requires Bun 1.3.13"
  exit 65
}

(
  cd "$web_root"
  npm ci --ignore-scripts --no-audit --no-fund
  npm test
  npm run build
)

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/mien-result-renderer.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
cp "$web_root/index.html" "$staging_root/index.html"
cp "$web_root/dist/renderer.js" "$staging_root/renderer.js"
cp "$web_root/dist/styles.css" "$staging_root/styles.css"

if $check_only; then
  [[ -d "$resource_root" ]] || {
    print -u2 "result renderer resources have not been generated"
    exit 65
  }
  diff -rq "$staging_root" "$resource_root" >/dev/null || {
    print -u2 "result renderer resources are stale; run scripts/build-result-renderer.sh"
    exit 65
  }
  print "result renderer resources verified"
  exit 0
fi

mkdir -p "${resource_root:h}"
rm -rf "$resource_root"
mkdir -p "$resource_root"
cp "$staging_root/"* "$resource_root/"
print "$resource_root"
