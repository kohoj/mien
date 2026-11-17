#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
mode="${1:-run}"
installed_app="/Applications/Mien.app"
installed_executable="$installed_app/Contents/MacOS/Mien"
log_subsystem="io.github.kohoj.mien"

usage() {
  print -u2 "usage: $0 [run|--debug|--logs|--telemetry|--verify]"
}

build_and_install() {
  "$project_root/scripts/assemble-app.sh"
  "$project_root/scripts/install-app.sh"
}

exact_installed_pids() {
  ps -axo pid=,comm= | awk -v executable="$installed_executable" \
    '$2 == executable { print $1 }'
}

case "$mode" in
  run)
    build_and_install
    ;;
  --verify|verify)
    build_and_install
    pids=("${(@f)$(exact_installed_pids)}")
    pids=("${(@)pids:#}")
    (( ${#pids} == 1 )) || {
      print -u2 "expected one exact Mien process, found ${#pids}: ${pids[*]}"
      exit 70
    }
    codesign --verify --deep --strict --verbose=2 "$installed_app"
    print "verified: $installed_executable (pid ${pids[1]})"
    ;;
  --debug|debug)
    "$project_root/scripts/assemble-app.sh"
    "$project_root/scripts/install-app.sh" --no-launch
    exec lldb -- "$installed_executable"
    ;;
  --logs|logs)
    build_and_install
    exec /usr/bin/log stream --info --style compact \
      --predicate 'process == "Mien"'
    ;;
  --telemetry|telemetry)
    build_and_install
    exec /usr/bin/log stream --info --style compact \
      --predicate "subsystem == \"$log_subsystem\""
    ;;
  *)
    usage
    exit 64
    ;;
esac
