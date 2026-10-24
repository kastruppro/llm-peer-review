#!/bin/bash
# Extract only the final reviewer response from an `agy --output-format json` envelope.
# With --json-schema, agy puts the payload in `.structured_output` (object) and a raw
# copy in `.response`; the object wins and is emitted as compact JSON. An envelope with
# no structured_output object and an empty/whitespace `.response` is rejected (agy exits
# 0 with status SUCCESS even when plan-mode/sandbox denied every action).
set -euo pipefail

RAW="${1:?usage: extract-agy-response.sh <agy-output.json>}"
[ -f "$RAW" ] || { echo "extract-agy-response: missing input: $RAW" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "extract-agy-response: jq not found" >&2; exit 64; }

if ! jq -e 'type == "object" and .status == "SUCCESS" and ((.structured_output | type == "object") or (.response | type == "string"))' "$RAW" >/dev/null 2>&1; then
  STATUS="$(jq -r 'if type == "object" then (.status // "MISSING_STATUS") else "INVALID_ENVELOPE" end' "$RAW" 2>/dev/null || printf 'INVALID_JSON')"
  echo "extract-agy-response: unusable agy envelope (status=$STATUS)" >&2
  exit 65
fi

if jq -e '.structured_output | type == "object"' "$RAW" >/dev/null 2>&1; then
  jq -c '.structured_output' "$RAW"
  exit 0
fi

if ! jq -e '.response | test("[^[:space:]]")' "$RAW" >/dev/null 2>&1; then
  echo "extract-agy-response: empty response and no structured_output (denied_actions: $(jq -c '.denied_actions // []' "$RAW" 2>/dev/null))" >&2
  exit 65
fi
jq -r '.response' "$RAW"
