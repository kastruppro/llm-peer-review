#!/bin/bash
# Extract only the final reviewer response from an `agy --output-format json` envelope.
set -euo pipefail

RAW="${1:?usage: extract-agy-response.sh <agy-output.json>}"
[ -f "$RAW" ] || { echo "extract-agy-response: missing input: $RAW" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "extract-agy-response: jq not found" >&2; exit 64; }

if ! jq -e 'type == "object" and .status == "SUCCESS" and (.response | type == "string")' "$RAW" >/dev/null 2>&1; then
  STATUS="$(jq -r 'if type == "object" then (.status // "MISSING_STATUS") else "INVALID_ENVELOPE" end' "$RAW" 2>/dev/null || printf 'INVALID_JSON')"
  echo "extract-agy-response: unusable agy envelope (status=$STATUS)" >&2
  exit 65
fi

jq -r '.response' "$RAW"
