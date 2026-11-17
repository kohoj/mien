#!/bin/zsh
set -euo pipefail

manifest=""
digests=""
output=""
renderer_components=""

usage() {
  print -u2 "usage: $0 --manifest FILE --digests FILE --renderer-components FILE --output FILE"
}

while (( $# > 0 )); do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    --digests) digests="$2"; shift 2 ;;
    --renderer-components) renderer_components="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ -f "$manifest" && -f "$digests" && -f "$renderer_components" && "$output" == /*.json ]] || {
  usage
  exit 64
}

mkdir -p "${output:h}"
jq -n \
  --slurpfile manifest "$manifest" \
  --slurpfile digests "$digests" \
  --slurpfile renderer "$renderer_components" \
  '{
    bomFormat: "CycloneDX",
    specVersion: "1.5",
    version: 1,
    metadata: {
      component: {
        type: "application",
        name: "Mien",
        version: "0.1.0"
      }
    },
    components: ([
      {
        type: "application",
        name: "Pi Agent Harness",
        version: $manifest[0].piAgent.version,
        purl: ("pkg:github/earendil-works/pi@" + $manifest[0].piAgent.commit),
        hashes: [{alg: "SHA-256", content: $digests[0].piAgent}],
        licenses: [{license: {id: "MIT"}}]
      },
      {
        type: "application",
        name: "Longview",
        version: $manifest[0].longview.commit,
        purl: ("pkg:github/kohoj/longview@" + $manifest[0].longview.commit),
        hashes: [{alg: "SHA-256", content: $digests[0].longview}],
        licenses: [{license: {id: "MIT"}}]
      }
    ] + $renderer[0].components)
  }' > "$output"
