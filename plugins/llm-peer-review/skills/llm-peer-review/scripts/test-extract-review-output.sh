#!/bin/bash
# Regression fixtures for the mixed-format final review gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT="$SCRIPT_DIR/extract-review-output.sh"
CLASSIFY="$SCRIPT_DIR/classify-review.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-final-extract.XXXXXX")"

cleanup() {
  local fixture
  for fixture in "$TEST_DIR"/*; do
    [ -f "$fixture" ] && rm -f -- "$fixture"
  done
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

CLAUDE="$TEST_DIR/review_claude_fixture.json"
printf '%s\n' '{"type":"result","is_error":false,"result":"HIGH src/a.py:12 first issue.\nHIGH src/b.ts:21 second issue.\nCHECKED: src/"}' > "$CLAUDE"
"$EXTRACT" "$CLAUDE" > "$TEST_DIR/claude.md"
grep -Fxq 'HIGH src/a.py:12 first issue.' "$TEST_DIR/claude.md"

AGY_RAW="$TEST_DIR/review_gemini_fixture.raw.json"
printf '%s\n' '{"status":"SUCCESS","internal_dialog":["noise/false.py:99"],"response":"HIGH web/index.html:8 first issue.\nHIGH scripts/run.ps1:14 second issue.\nCHECKED: web/, scripts/"}' > "$AGY_RAW"
"$EXTRACT" "$AGY_RAW" > "$TEST_DIR/agy.md"
grep -Fxq 'HIGH web/index.html:8 first issue.' "$TEST_DIR/agy.md"
! grep -Fq 'noise/false.py:99' "$TEST_DIR/agy.md"

# This is the reported failure: Markdown content with a historical .json suffix.
GEMINI="$TEST_DIR/review_gemini_fixture.json"
printf '%s\n' 'HIGH app/main.swift:31 first issue.' 'HIGH app/state.swift:42 second issue.' 'CHECKED: app/' > "$GEMINI"
"$EXTRACT" "$GEMINI" > "$TEST_DIR/gemini.md"
cmp "$GEMINI" "$TEST_DIR/gemini.md"
[ "$("$CLASSIFY" "$TEST_DIR/gemini.md" 2>/dev/null)" = 'VALID' ]

CODEX="$TEST_DIR/review_codex_fixture.last.md"
printf '%s\n' 'NO_FINDINGS' 'CHECKED: Sources/App.swift' > "$CODEX"
"$EXTRACT" "$CODEX" > "$TEST_DIR/codex.md"
cmp "$CODEX" "$TEST_DIR/codex.md"

ERROR_ENVELOPE="$TEST_DIR/error.json"
printf '%s\n' '{"type":"result","is_error":true,"result":"failed"}' > "$ERROR_ENVELOPE"
if "$EXTRACT" "$ERROR_ENVELOPE" >/dev/null 2>&1; then
  echo 'not ok - error envelope passed the final gate' >&2
  exit 1
fi

printf '%s\n' 'ok - final gate extracts envelopes and accepts Markdown regardless of suffix'
