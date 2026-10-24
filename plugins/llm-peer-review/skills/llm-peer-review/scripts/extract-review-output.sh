#!/bin/bash
# Content-aware final-gate extraction for Claude, Gemini/AGY, and Codex outputs.
set -euo pipefail

INPUT="${1:?usage: extract-review-output.sh <review-output-file>}"
[ -f "$INPUT" ] || { echo "extract-review-output: missing input: $INPUT" >&2; exit 64; }
[ -s "$INPUT" ] || { echo "extract-review-output: empty input: $INPUT" >&2; exit 65; }
command -v jq >/dev/null 2>&1 || { echo "extract-review-output: jq not found" >&2; exit 64; }

# A legacy .json suffix does not imply a JSON envelope: the published Gemini
# vote is extracted Markdown. Parse only content that is actually valid JSON.
if ! jq -e . "$INPUT" >/dev/null 2>&1; then
  cat "$INPUT"
  exit 0
fi

KIND="$(jq -r '
  if type != "object" then "direct-json"
  elif (has("status") or has("response")) then
    if .status == "SUCCESS" and (.response | type == "string") then "agy"
    else "error"
    end
  elif (has("is_error") or has("result") or has("structured_output")) then
    if .is_error == true then "error"
    elif has("structured_output") and .structured_output != null then "structured"
    elif (.result | type == "string") then "claude"
    else "error"
    end
  else "direct-json"
  end
' "$INPUT")"

case "$KIND" in
  agy)
    jq -r '.response' "$INPUT"
    ;;
  claude)
    jq -r '.result' "$INPUT"
    ;;
  structured)
    jq -r '.structured_output | if type == "string" then . else tojson end' "$INPUT"
    ;;
  direct-json)
    cat "$INPUT"
    ;;
  error)
    echo "extract-review-output: reviewer error or unusable envelope: $INPUT" >&2
    exit 65
    ;;
  *)
    echo "extract-review-output: internal kind error: $KIND" >&2
    exit 70
    ;;
esac
