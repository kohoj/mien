#!/bin/zsh
set -euo pipefail

manifest=""
digests=""
output=""

usage() {
  print -u2 "usage: $0 --manifest FILE --digests FILE --output FILE"
}

while (( $# > 0 )); do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    --digests) digests="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ -f "$manifest" && -f "$digests" && "$output" == /*.json ]] || {
  usage
  exit 64
}

mkdir -p "${output:h}"
jq -n \
  --slurpfile manifest "$manifest" \
  --slurpfile digests "$digests" \
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
    components: [
      {
        type: "application",
        name: "OpenAI Codex",
        version: $manifest[0].codex.version,
        purl: ("pkg:github/openai/codex@" + $manifest[0].codex.commit),
        hashes: [{alg: "SHA-256", content: $digests[0].codex}],
        licenses: [{license: {id: "Apache-2.0"}}]
      },
      {
        type: "application",
        name: "Codex ACP",
        version: $manifest[0].codexACP.version,
        purl: ("pkg:github/agentclientprotocol/codex-acp@" + $manifest[0].codexACP.commit),
        hashes: [{alg: "SHA-256", content: $digests[0].codexACP}],
        licenses: [{license: {id: "Apache-2.0"}}]
      },
      {
        type: "application",
        name: "Longview",
        version: $manifest[0].longview.commit,
        purl: ("pkg:github/kohoj/longview@" + $manifest[0].longview.commit),
        hashes: [{alg: "SHA-256", content: $digests[0].longview}],
        licenses: [{license: {id: "MIT"}}]
      }
    ]
  }' > "$output"
