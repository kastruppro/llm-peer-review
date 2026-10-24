#!/bin/bash
# Regression fixtures for AGY final-response extraction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT="$SCRIPT_DIR/extract-agy-response.sh"
CLASSIFIER="$SCRIPT_DIR/classify-review.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-agy-extract.XXXXXX")"

cleanup() {
  local fixture
  for fixture in "$TEST_DIR"/*; do
    [ -e "$fixture" ] && rm -f -- "$fixture"
  done
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

RAW="$TEST_DIR/noisy-session.json"
FINAL="$TEST_DIR/final.md"
printf '%s\n' '{"conversation_id":"fixture","status":"SUCCESS","internal_dialog":["Let us inspect src/noise.ts:10","Wait! tools found src/more.py:20"],"response":"{\"verdict\":\"approve\",\"summary\":\"No issues.\",\"findings\":[],\"checked\":[\"scripts/Detect.ps1\",\"frontend/index.html\"],\"next_steps\":[]}"}' > "$RAW"
"$EXTRACT" "$RAW" > "$FINAL"

grep -Fq '"verdict":"approve"' "$FINAL"
grep -Fq 'scripts/Detect.ps1' "$FINAL"
if grep -Fq 'src/noise.ts:10' "$FINAL"; then
  echo 'not ok - internal dialog leaked into extracted response' >&2
  exit 1
fi
VERDICT="$("$CLASSIFIER" "$FINAL" 2>/dev/null)"
[ "$VERDICT" = 'CLEAN' ] || { echo "not ok - expected CLEAN, got $VERDICT" >&2; exit 1; }
printf '%s\n' 'ok - noisy envelope extracts to CLEAN final response'

printf '%s\n' '{"status":"ERROR","response":"src/noise.ts:10 src/more.py:20"}' > "$TEST_DIR/error.json"
if "$EXTRACT" "$TEST_DIR/error.json" > "$TEST_DIR/error.md" 2>/dev/null; then
  echo 'not ok - non-success envelope was accepted' >&2
  exit 1
fi
printf '%s\n' 'ok - non-success envelope rejected'

printf '%s\n' 'not-json' > "$TEST_DIR/invalid.json"
if "$EXTRACT" "$TEST_DIR/invalid.json" > "$TEST_DIR/invalid.md" 2>/dev/null; then
  echo 'not ok - invalid JSON was accepted' >&2
  exit 1
fi
printf '%s\n' 'ok - invalid JSON rejected'

printf '%s\n' '{"status":"SUCCESS","response":"prose that must lose","structured_output":{"verdict":"approve","summary":"s","findings":[],"checked":["a.py"],"next_steps":[]}}' > "$TEST_DIR/structured.json"
"$EXTRACT" "$TEST_DIR/structured.json" > "$TEST_DIR/structured.out"
[ "$(wc -l < "$TEST_DIR/structured.out" | tr -d ' ')" = '1' ] || { echo 'not ok - structured_output not compact' >&2; exit 1; }
grep -Fq '"verdict":"approve"' "$TEST_DIR/structured.out" || { echo 'not ok - structured_output not emitted' >&2; exit 1; }
if grep -Fq 'prose that must lose' "$TEST_DIR/structured.out"; then
  echo 'not ok - response emitted despite structured_output' >&2
  exit 1
fi
printf '%s\n' 'ok - structured_output object preferred over response'

printf '%s\n' '{"status":"SUCCESS","response":"  \n ","denied_actions":[{"action":"command"}]}' > "$TEST_DIR/empty.json"
if "$EXTRACT" "$TEST_DIR/empty.json" > "$TEST_DIR/empty.out" 2>/dev/null; then
  echo 'not ok - empty response without structured_output was accepted' >&2
  exit 1
fi
printf '%s\n' 'ok - empty response without structured_output rejected'
