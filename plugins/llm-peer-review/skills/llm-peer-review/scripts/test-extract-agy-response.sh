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
printf '%s\n' '{"conversation_id":"fixture","status":"SUCCESS","internal_dialog":["Let us inspect src/noise.ts:10","Wait! tools found src/more.py:20"],"response":"NO_FINDINGS\n\nCHECKED:\n- scripts/Detect.ps1\n- frontend/index.html\n"}' > "$RAW"
"$EXTRACT" "$RAW" > "$FINAL"

grep -Fxq 'NO_FINDINGS' "$FINAL"
grep -Fxq -- '- scripts/Detect.ps1' "$FINAL"
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
