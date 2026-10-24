#!/bin/bash
# End-to-end wrapper fixture with a fake `agy`: WEAK first attempt, CLEAN retry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/gemini-review.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-gemini-wrapper.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
REVIEW_ROOT="$TEST_DIR/review"
PROJECT_ROOT="$TEST_DIR/project"
COUNTER="$TEST_DIR/agy-counter"
mkdir -p "$FAKE_BIN" "$REVIEW_ROOT" "$PROJECT_ROOT"

cleanup() {
  local fixture
  for fixture in "$REVIEW_ROOT"/* "$FAKE_BIN"/* "$TEST_DIR"/*; do
    [ -f "$fixture" ] && rm -f -- "$fixture"
  done
  rmdir "$REVIEW_ROOT" "$PROJECT_ROOT" "$FAKE_BIN" "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

FAKE_AGY="$FAKE_BIN/agy"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [ "${1:-}" = "models" ]; then' \
  '  printf "%s\n" '\''gemini-3.8-flash-high\tGemini 3.8 Flash (High)'\''' \
  '  exit 0' \
  'fi' \
  'printf "%s\n" "$*" | grep -Fq -- "--output-format json"' \
  'printf "%s\n" "$*" | grep -Fq -- "--print-timeout ${AGY_EXPECTED_CAP}s"' \
  'COUNT=0' \
  '[ -f "$AGY_FAKE_COUNTER" ] && COUNT="$(sed -n "1p" "$AGY_FAKE_COUNTER")"' \
  'COUNT=$((COUNT + 1))' \
  'printf "%s\n" "$COUNT" > "$AGY_FAKE_COUNTER"' \
  'if [ "$COUNT" -eq 1 ]; then' \
  '  printf "%s\n" '\''{"status":"SUCCESS","response":"NO_FINDINGS\n\nCHECKED:\nNo concrete list was supplied.\n"}'\''' \
  'else' \
  '  printf "%s\n" '\''{"status":"SUCCESS","internal_dialog":["Let us inspect src/noise.ts:10","Wait! src/more.py:20"],"response":"NO_FINDINGS\n\nCHECKED:\n- scripts/Detect.ps1\n- frontend/index.html\n"}'\''' \
  'fi' > "$FAKE_AGY"
chmod +x "$FAKE_AGY"

export AGY_FAKE_COUNTER="$COUNTER"
export AGY_EXPECTED_CAP=900
unset GEMINI_ATTEMPT_CAP
PATH="$FAKE_BIN:$PATH" \
REVIEW_DIR="$REVIEW_ROOT" \
  "$WRAPPER" fixture 'Review the supplied project and return the required contract.' "$PROJECT_ROOT"

BASE="$REVIEW_ROOT/review_gemini_fixture"
[ "$(sed -n '1p' "$COUNTER")" = '2' ]
[ -f "$BASE.attempt1.raw.json" ]
[ -f "$BASE.attempt1.final.md" ]
[ -f "$BASE.attempt1.classify.txt" ]
[ -f "$BASE.attempt2.raw.json" ]
[ -f "$BASE.attempt2.final.md" ]
[ -f "$BASE.attempt2.classify.txt" ]
grep -Fxq 'verdict=WEAK' "$BASE.attempt1.classify.txt"
grep -Fxq 'verdict=CLEAN' "$BASE.attempt2.classify.txt"
grep -Fxq 'GEMINI:agy' "$BASE.VOICE"
grep -Fxq -- '- scripts/Detect.ps1' "$BASE.json"
if grep -Fq 'src/noise.ts:10' "$BASE.json"; then
  echo 'internal dialog leaked into published response' >&2
  exit 1
fi
[ ! -e "$BASE.SKIPPED" ]
grep -Fxq '[attempt1 classification]' "$BASE.err"
grep -Fxq '[attempt2 classification]' "$BASE.err"
grep -Fxq '[attempt1 artifacts]' "$BASE.err"
grep -Fxq '[attempt2 artifacts]' "$BASE.err"

PATH="$FAKE_BIN:$PATH" \
REVIEW_DIR="$REVIEW_ROOT" \
GEMINI_ATTEMPT_CAP=30 AGY_EXPECTED_CAP=30 \
  "$WRAPPER" override 'Review with an explicit attempt limit.' "$PROJECT_ROOT"
[ -f "$REVIEW_ROOT/review_gemini_override.VOICE" ]

set +e
PATH="$FAKE_BIN:$PATH" \
REVIEW_DIR="$REVIEW_ROOT" \
GEMINI_REVIEW_MODEL='gemini-9-unknown-high' \
  "$WRAPPER" unknown 'This must fail model validation.' "$PROJECT_ROOT" >/dev/null 2>&1
UNKNOWN_RC=$?
set -e
[ "$UNKNOWN_RC" -eq 64 ]

printf '%s\n' 'ok - literal \\t model listing parses exactly, unknown IDs fail, and CLEAN retry evidence is preserved'
