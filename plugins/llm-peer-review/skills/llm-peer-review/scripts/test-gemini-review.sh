#!/bin/bash
# End-to-end wrapper fixture with a fake `agy`: WEAK first attempt (empty `checked`), CLEAN retry.
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
  'printf "%s\n" "$*" | grep -Fq -- "--json-schema ${AGY_EXPECTED_SCHEMA}"' \
  'printf "%s\n" "$*" | grep -Fq -- "--mode plan"' \
  'printf "%s\n" "$*" | grep -Fq -- "--sandbox"' \
  'printf "%s\n" "$*" | grep -Fq -- "--dangerously-skip-permissions"' \
  'if printf "%s\n" "$*" | grep -Fq -- "--disable-slash-commands"; then exit 3; fi' \
  'printf "%s\n" "$*" | grep -Fq -- "--add-dir ${AGY_EXPECTED_SHARED} --add-dir ${AGY_EXPECTED_CWD} --"' \
  'if printf "%s\n" "$*" | grep -Fq -- "--add-dir ${AGY_EXPECTED_REVIEW} "; then exit 4; fi' \
  'printf "%s\n" "$*" | grep -Fq -- "--print-timeout ${AGY_EXPECTED_CAP}s"' \
  'COUNT=0' \
  '[ -f "$AGY_FAKE_COUNTER" ] && COUNT="$(sed -n "1p" "$AGY_FAKE_COUNTER")"' \
  'COUNT=$((COUNT + 1))' \
  'printf "%s\n" "$COUNT" > "$AGY_FAKE_COUNTER"' \
  'if [ "$COUNT" -eq 1 ]; then' \
  '  printf "%s\n" '\''{"status":"SUCCESS","response":"{\"verdict\":\"approve\",\"summary\":\"s\",\"findings\":[],\"checked\":[],\"next_steps\":[]}"}'\''' \
  'else' \
  '  printf "%s\n" '\''{"status":"SUCCESS","internal_dialog":["Let us inspect src/noise.ts:10","Wait! src/more.py:20"],"response":"{\"verdict\":\"approve\",\"summary\":\"s\",\"findings\":[],\"checked\":[\"scripts/Detect.ps1\",\"frontend/index.html\"],\"next_steps\":[]}"}'\''' \
  'fi' > "$FAKE_AGY"
chmod +x "$FAKE_AGY"

export AGY_FAKE_COUNTER="$COUNTER"
export AGY_EXPECTED_CAP=900
export AGY_EXPECTED_SCHEMA="$SCRIPT_DIR/../schemas/review-output.schema.json"
export AGY_EXPECTED_SHARED="$REVIEW_ROOT/shared"
export AGY_EXPECTED_CWD="$PROJECT_ROOT"
export AGY_EXPECTED_REVIEW="$REVIEW_ROOT"
mkdir -p "$REVIEW_ROOT/shared"
unset GEMINI_ATTEMPT_CAP
AGY_BIN="$FAKE_AGY" \
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
grep -Fq 'scripts/Detect.ps1' "$BASE.json"
if grep -Fq 'src/noise.ts:10' "$BASE.json"; then
  echo 'internal dialog leaked into published response' >&2
  exit 1
fi
[ ! -e "$BASE.SKIPPED" ]
grep -Fxq '[attempt1 classification]' "$BASE.err"
grep -Fxq '[attempt2 classification]' "$BASE.err"
grep -Fxq '[attempt1 artifacts]' "$BASE.err"
grep -Fxq '[attempt2 artifacts]' "$BASE.err"

AGY_BIN="$FAKE_AGY" \
REVIEW_DIR="$REVIEW_ROOT" \
GEMINI_ATTEMPT_CAP=30 AGY_EXPECTED_CAP=30 \
  "$WRAPPER" override 'Review with an explicit attempt limit.' "$PROJECT_ROOT"
[ -f "$REVIEW_ROOT/review_gemini_override.VOICE" ]

set +e
AGY_BIN="$FAKE_AGY" \
REVIEW_DIR="$REVIEW_ROOT" \
GEMINI_REVIEW_MODEL='gemini-9-unknown-high' \
  "$WRAPPER" unknown 'This must fail model validation.' "$PROJECT_ROOT" >/dev/null 2>&1
UNKNOWN_RC=$?
set -e
[ "$UNKNOWN_RC" -eq 64 ]

printf '%s\n' 'ok - literal \\t model listing parses exactly, unknown IDs fail, and CLEAN retry evidence is preserved'
