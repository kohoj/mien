#!/bin/zsh
set -euo pipefail

# Installs the assembled app and touches TCC only when the code signature
# actually changed.
#
# TCC binds a grant to the code signature. Ad-hoc signing (the default in
# assemble-app.sh) has no stable identity, so the grant is pinned to the CDHash:
# rebuild after a source change and the grant silently stops applying while the
# toggle in System Settings still looks enabled. Resetting is the cure for that,
# but resetting unconditionally makes the user re-authorise after every install
# even when nothing about the signature moved.

project_root="${0:A:h:h}"
bundle_id="io.github.kohoj.mien"
source_app="$project_root/.build/distribution/Mien.app"
target_app="/Applications/Mien.app"
launch=1

usage() {
  print -u2 "usage: $0 [--source APP] [--target APP] [--no-launch]"
}

while (( $# > 0 )); do
  case "$1" in
    --source) source_app="$2"; shift 2 ;;
    --target) target_app="$2"; shift 2 ;;
    --no-launch) launch=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ -d "$source_app" ]] || { print -u2 "no assembled app at $source_app"; exit 66; }

code_directory_hash() {
  [[ -d "$1" ]] || return 1
  codesign -dvvv "$1" 2>&1 | awk '
    /^CandidateCDHash sha256=/ && !found {
      sub(/^CandidateCDHash sha256=/, "")
      print
      found = 1
    }
  '
}

previous_hash="$(code_directory_hash "$target_app" || true)"
next_hash="$(code_directory_hash "$source_app" || true)"
[[ -n "$next_hash" ]] || { print -u2 "cannot read the code directory hash of $source_app"; exit 65; }

installed_executable="$target_app/Contents/MacOS/Mien"
installed_pids=("${(@f)$(ps -axo pid=,comm= | awk -v executable="$installed_executable" '$2 == executable { print $1 }')}")
installed_pids=("${(@)installed_pids:#}")
if (( ${#installed_pids} > 0 )); then
  kill "${installed_pids[@]}"
  for attempt in {1..50}; do
    remaining=()
    for pid in "${installed_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && remaining+=("$pid")
    done
    (( ${#remaining} == 0 )) && break
    sleep 0.1
  done
  (( ${#remaining} == 0 )) || {
    print -u2 "installed Mien process did not stop: ${remaining[*]}"
    exit 70
  }
fi

rm -rf "$target_app"
ditto "$source_app" "$target_app"

if [[ "$previous_hash" == "$next_hash" ]]; then
  print "code signature unchanged ($next_hash) — existing authorization still applies"
else
  print "code signature changed:"
  print "  was $previous_hash"
  print "  now $next_hash"
  # The old grant is bound to a signature that no longer exists. Leaving it in
  # place is worse than clearing it: System Settings would show Mien enabled
  # while every accessibility read fails.
  tccutil reset Accessibility "$bundle_id" >/dev/null
  tccutil reset ScreenCapture "$bundle_id" >/dev/null
  print "  authorization reset — Mien will ask for capabilities again:"
  print "    · Interface content — the recommended first sensing route"
  print "    · Current frame — optional until the Agent requests visual evidence;"
  print "      macOS may require granting it directly in System Settings:"
  print "      open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"
fi

if (( launch )); then
  open -a "$target_app"
  sleep 3
  launched_pid="$(ps -axo pid=,comm= | awk -v executable="$installed_executable" '$2 == executable && !found { print $1; found = 1 }')"
  if [[ -n "$launched_pid" ]]; then
    print "running: pid $launched_pid"
  else
    print -u2 "Mien did not start"
    exit 70
  fi
fi
