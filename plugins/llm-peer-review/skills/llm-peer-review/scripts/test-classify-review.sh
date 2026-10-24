#!/bin/bash
# Regression fixtures for classify-review.sh (schema-based classes + error-body precedence).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER="$SCRIPT_DIR/classify-review.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-classifier.XXXXXX")"
FAILURES=0

cleanup() {
  local fixture
  for fixture in "$TEST_DIR"/*; do
    [ -e "$fixture" ] && rm -f -- "$fixture"
  done
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

assert_verdict() {
  local name="$1" expected="$2" expected_rc="$3" actual rc output err
  shift 3
  output="$TEST_DIR/$name.md"
  err="$TEST_DIR/$name.err"
  printf '%s\n' "$@" > "$output"

  if actual="$("$CLASSIFIER" "$output" 2>"$err")"; then
    rc=0
  else
    rc=$?
  fi

  if [ "$actual" = "$expected" ] && [ "$rc" -eq "$expected_rc" ]; then
    printf 'ok - %s => %s\n' "$name" "$actual"
  else
    printf 'not ok - %s: expected %s/%s, got %s/%s\n' \
      "$name" "$expected" "$expected_rc" "$actual" "$rc" >&2
    sed 's/^/  /' "$err" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# --- helpers for file-based and generated JSON fixtures ----------------------
assert_file() {
  local name="$1" expected="$2" expected_rc="$3" src="$4" output="$TEST_DIR/$1.md"
  cp "$src" "$output"
  assert_existing "$name" "$expected" "$expected_rc" "$output"
}
assert_existing() {
  local name="$1" expected="$2" expected_rc="$3" output="$4" actual rc err="$TEST_DIR/$1.err"
  if actual="$("$CLASSIFIER" "$output" 2>"$err")"; then rc=0; else rc=$?; fi
  if [ "$actual" = "$expected" ] && [ "$rc" -eq "$expected_rc" ]; then
    printf 'ok - %s => %s\n' "$name" "$actual"
  else
    printf 'not ok - %s: expected %s/%s, got %s/%s\n' \
      "$name" "$expected" "$expected_rc" "$actual" "$rc" >&2
    sed 's/^/  /' "$err" >&2
    FAILURES=$((FAILURES + 1))
  fi
}
# json_review <verdict> <body> <findings-json> <checked-json>
json_review() {
  printf '{"verdict":"%s","summary":"s","findings":%s,"checked":%s,"next_steps":[]}\n' "$1" "$3" "$4"
}
finding() {  # finding <body>
  printf '[{"severity":"high","title":"t","body":"%s","file":"src/a.py","line_start":3,"line_end":3,"confidence":0.9,"recommendation":"r"}]' "$1"
}

# --- real CLI outputs captured in Task 2 ------------------------------------
assert_file fixture_claude_envelope VALID 0 "$FIXTURES/claude-envelope.json"
assert_file fixture_codex_last      VALID 0 "$FIXTURES/codex-last.json"
assert_file fixture_agy_envelope    VALID 0 "$FIXTURES/agy-envelope.json"

# --- schema-based classes ---------------------------------------------------
json_review needs-attention x "$(finding 'Off by one.')" '["src/a.py"]' > "$TEST_DIR/json_valid.md"
assert_existing json_valid VALID 0 "$TEST_DIR/json_valid.md"

json_review approve x '[]' '["src/a.py"]' > "$TEST_DIR/json_clean.md"
assert_existing json_clean CLEAN 0 "$TEST_DIR/json_clean.md"

json_review approve x '[]' '[]' > "$TEST_DIR/json_clean_unattested.md"
assert_existing json_clean_unattested WEAK 5 "$TEST_DIR/json_clean_unattested.md"

json_review needs-attention x '[]' '["src/a.py"]' > "$TEST_DIR/json_attention_empty.md"
assert_existing json_attention_empty WEAK 5 "$TEST_DIR/json_attention_empty.md"

# Capacity tokens quoted inside a schema-valid review must not turn it into CAPACITY.
json_review needs-attention x "$(finding 'Handler swallows RESOURCE_EXHAUSTED and ECONNREFUSED errors.')" '["src/a.py"]' > "$TEST_DIR/quoted_capacity.md"
assert_existing quoted_capacity_in_valid_review VALID 0 "$TEST_DIR/quoted_capacity.md"

# Fenced JSON inside an agy envelope (Review Focus 3).
printf '%s\n' '{"status":"SUCCESS","response":"```json\n{\"verdict\":\"approve\",\"summary\":\"s\",\"findings\":[],\"checked\":[\"src/a.py\"],\"next_steps\":[]}\n```"}' > "$TEST_DIR/fenced.md"
assert_existing fenced_agy_response CLEAN 0 "$TEST_DIR/fenced.md"

# --- prose and text-contract output is no longer valid ----------------------
assert_verdict prose_with_locations WEAK 5 \
  'HIGH scripts/Detect.ps1:12 race condition permits stale state.' \
  'MEDIUM modules/Repair.psm1:34 path traversal accepts unsafe input.'

assert_verdict old_text_contract WEAK 5 \
  'NO_FINDINGS' \
  'CHECKED: app/, frontend/, scripts/, and deployment configuration.'

assert_verdict url_ports_are_not_locations WEAK 5 \
  'The service contacts https://api.example.com:443 and https://status.example.net:8443 during normal operation.'

# --- failures that masquerade as content ------------------------------------
assert_verdict capacity_beats_stack_locations CAPACITY 3 \
  'TerminalQuotaError while processing /bundle/chunk-one.js:304211 and /bundle/chunk-two.js:304299.'

assert_verdict claude_error_envelope ERROR 6 \
  '{"type":"result","is_error":true,"result":"Execution error while reviewing the supplied project."}'

assert_verdict agy_non_success_envelope ERROR 6 \
  '{"status":"ERROR","response":"model unavailable while reviewing the project"}'

# The body gemini-review.sh writes when agy produced nothing extractable.
assert_verdict agy_failure_body ERROR 6 \
  'AGY did not produce an extractable final response. See /tmp/x.raw.json and /tmp/x.err.' \
  '{"is_error":true}'

assert_verdict refusal REFUSED 7 \
  "I'm sorry, but I cannot fulfill your request to analyze the code for security vulnerabilities."

assert_verdict misfire MISFIRE 4 \
  'The reviewers are launched in the background and I will now wait for the consolidated output.'

assert_verdict soft_capacity CAPACITY 3 \
  'Request failed: 429 Too Many Requests from the upstream service while reading the repository.'

assert_verdict empty EMPTY 2 'x'

# A reviewed auth topic is not a failed reviewer authentication.
json_review needs-attention x "$(finding 'Unauthorized users can read private records.')" '["src/auth.ts"]' > "$TEST_DIR/auth_topic.md"
assert_existing structured_unauthorized_impact VALID 0 "$TEST_DIR/auth_topic.md"

assert_verdict unauthorized_cli_failure CAPACITY 3 \
  'Unauthorized: access token expired; authenticate with the provider again.'

assert_verdict unauthorized_json_failure CAPACITY 3 \
  '{"error":"Unauthorized","message":"The supplied credentials have expired."}'

# Sourced use (wait-for-reviewers.sh / gemini-review.sh) keeps working from any cwd.
sourced="$(cd / && bash -c 'source "$1" && classify_review "$2"' _ "$CLASSIFIER" "$TEST_DIR/json_clean.md" 2>/dev/null)"
if [ "$sourced" = CLEAN ]; then
  printf 'ok - sourced classify_review => CLEAN\n'
else
  printf 'not ok - sourced classify_review: got %s\n' "$sourced" >&2
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then
  printf '%s classifier fixture(s) failed.\n' "$FAILURES" >&2
  exit 1
fi

printf 'All classifier fixtures passed.\n'
