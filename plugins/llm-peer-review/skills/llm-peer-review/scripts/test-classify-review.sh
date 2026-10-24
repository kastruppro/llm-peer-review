#!/bin/bash
# Regression fixtures for classify-review.sh location and precedence rules.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER="$SCRIPT_DIR/classify-review.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-classifier.XXXXXX")"
FAILURES=0

cleanup() {
  local fixture
  for fixture in "$TEST_DIR"/*.md "$TEST_DIR"/*.err; do
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

assert_verdict powershell VALID 0 \
  'HIGH scripts/Detect.ps1:12 race condition permits stale state.' \
  'MEDIUM modules/Repair.psm1:34 path traversal accepts unsafe input.'

assert_verdict python_typescript VALID 0 \
  'HIGH app/services/scheduler.py:81 non-atomic update loses work.' \
  'MEDIUM frontend/src/api.ts:44 race condition returns stale data.'

assert_verdict root_python_html VALID 0 \
  'HIGH service.py:17 non-atomic update loses work.' \
  'MEDIUM index.html:29 unsafe output reaches the page.'

assert_verdict root_typescript VALID 0 \
  'HIGH client.ts:31 race condition returns stale data.' \
  'MEDIUM component.tsx:58 null deref crashes rendering.'

assert_verdict web_formats VALID 0 \
  'HIGH frontend/index.html:27 unsafe output reaches the page.' \
  'MEDIUM frontend/src/main.tsx:63 null deref crashes rendering.'

assert_verdict config_formats VALID 0 \
  'HIGH deploy/docker-compose.yml:19 configuration bypasses validation.' \
  'MEDIUM pyproject.toml:42 path traversal permits an unsafe path.'

assert_verdict future_path_extensions VALID 0 \
  'HIGH src/widget.customlang:7 non-atomic state change loses data.' \
  'MEDIUM config/rules.toolcfg:18 race condition reads partial state.'

assert_verdict root_and_extensionless VALID 0 \
  'HIGH worker.ps1:9 race condition permits stale state.' \
  'MEDIUM Dockerfile:22 path traversal copies unintended files.'

assert_verdict url_ports_are_not_locations WEAK 5 \
  'The service contacts https://api.example.com:443 and https://status.example.net:8443 during normal operation.'

assert_verdict one_location_is_weak WEAK 5 \
  'HIGH scripts/Detect.ps1:12 contains one possible race condition but no second concrete location.'

assert_verdict capacity_beats_stack_locations CAPACITY 3 \
  'TerminalQuotaError while processing /bundle/chunk-one.js:304211 and /bundle/chunk-two.js:304299.'

assert_verdict attested_clean CLEAN 0 \
  'NO_FINDINGS' \
  'CHECKED: app/, frontend/, scripts/, and deployment configuration.'

assert_verdict attested_clean_multiline CLEAN 0 \
  'NO_FINDINGS' \
  '' \
  'CHECKED:' \
  '- scripts/Detect.ps1' \
  '- frontend/index.html'

assert_verdict unattested_clean_multiline WEAK 5 \
  'NO_FINDINGS' \
  '' \
  'CHECKED:' \
  'The response did not provide a concrete Markdown list of checked files.'

assert_verdict vague_clean_multiline WEAK 5 \
  'NO_FINDINGS' \
  '' \
  'CHECKED:' \
  '- all files' \
  'This generic statement does not identify any concrete path or filename.'

assert_verdict single_structured VALID 0 \
  'Severity: P1' 'Location: src/auth.ts:42' \
  'Behavior: Requests are accepted without token validation.' \
  'Impact: An unauthenticated caller can read private records.' \
  'Fix: Validate the token before returning data.' 'CHECKED: src/auth.ts'

assert_verdict incomplete_structured WEAK 5 \
  'Severity: P1' 'Location: src/auth.ts:42' \
  'Behavior: Requests are accepted without token validation.' 'CHECKED: src/auth.ts'

assert_verdict single_envelope VALID 0 \
  '{"type":"result","is_error":false,"result":"Severity: P1\nLocation: src/auth.ts:42\nBehavior: Requests skip token validation.\nImpact: Private data is exposed.\nFix: Validate the token.\nCHECKED: src/auth.ts"}'

assert_verdict structured_error ERROR 6 \
  '{"type":"result","is_error":true,"result":"Severity: P1\nLocation: src/auth.ts:42\nBehavior: Requests skip token validation.\nImpact: Private data is exposed.\nFix: Validate the token.\nCHECKED: src/auth.ts"}'


# A reviewed auth topic is not a failed reviewer authentication.
assert_verdict clean_auth_topic CLEAN 0 \
  'NO_FINDINGS' 'CHECKED:' \
  '- frontend/src/App.svelte (unauthorized event navigation and cookie expiry)'

assert_verdict structured_unauthorized_impact VALID 0 \
  'Severity: P1' 'Location: src/auth.ts:42' \
  'Behavior: Requests skip validation.' \
  'Impact: Unauthorized users can read private records.' \
  'Fix: Validate the session.' 'CHECKED: src/auth.ts'

assert_verdict unauthorized_cli_failure CAPACITY 3 \
  'Unauthorized: access token expired; authenticate with the provider again.'

assert_verdict unauthorized_json_failure CAPACITY 3 \
  '{"error":"Unauthorized","message":"The supplied credentials have expired."}'

if [ "$FAILURES" -ne 0 ]; then
  printf '%s classifier fixture(s) failed.\n' "$FAILURES" >&2
  exit 1
fi

printf 'All classifier fixtures passed.\n'
