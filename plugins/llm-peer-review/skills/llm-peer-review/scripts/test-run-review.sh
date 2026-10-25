#!/bin/bash
# End-to-end test of run-review.sh with fake claude/codex/agy CLIs (no model calls).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$SCRIPT_DIR/run-review.sh"
FIX="$SCRIPT_DIR/fixtures"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-run-test.XXXXXX")" && pwd -P)"
FAKE_BIN="$T/bin"
FAKE_HOME="$T/home"
PROJ="$T/my project"
CALLS="$T/calls.log"
FAKE_MARKER=$((30000 + $$ % 20000)) # unique sleep duration: pgrep -f "sleep $FAKE_MARKER" finds leftovers
export FAKE_MARKER
mkdir -p "$FAKE_BIN" "$FAKE_HOME/.gemini/antigravity-cli" "$T/tmp"
# Fakes can outlive a failed/aborted run (they ignore TERM on purpose), so the
# trap kills anything carrying this run's marker or temp dir before removing it.
LEFTOVER_RE="marker-$FAKE_MARKER|sleep $FAKE_MARKER|$T/"
cleanup() {
  pkill -KILL -f "$LEFTOVER_RE" 2>/dev/null || true
  chmod -R u+w "$T" 2>/dev/null # run-review makes shared/ read-only
  rm -rf -- "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FAILS=0
ok() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }
check() { # check <desc> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

GEMINI_ID="$(bash "$SCRIPT_DIR/models.sh" gemini)"

cat > "$FAKE_BIN/claude" <<'FAKE'
#!/bin/bash
echo claude >> "$CALL_LOG"
shared=""; schema=""; prev=""
for a in "$@"; do
  [ "$prev" = "--add-dir" ] && shared="$a"
  [ "$prev" = "--json-schema" ] && schema="$a"
  prev="$a"
done
case "$shared" in */shared) [ -d "$shared" ] || exit 96 ;; *) exit 96 ;; esac
[ -n "$schema" ] || exit 95
case " $* " in *" --strict-mcp-config "*) ;; *) exit 93 ;; esac
[ -n "${*: -1}" ] || exit 94
if [ "${FAKE_CLAUDE_MODE:-}" = hang ]; then exec sleep "$FAKE_MARKER"; fi
if [ "${FAKE_CLAUDE_MODE:-}" = error ]; then
  printf '%s\n' '{"is_error":true,"subtype":"error_during_execution","result":"fake failure for the test"}'
  exit 0
fi
cat "$FAKE_FIXTURES/claude-envelope.json"
FAKE

cat > "$FAKE_BIN/codex" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "codex-cli 0.164.0"; exit 0; fi
echo codex >> "$CALL_LOG"
out=""; schema=""; prev=""
for a in "$@"; do
  [ "$prev" = "--output-last-message" ] && out="$a"
  [ "$prev" = "--output-schema" ] && schema="$a"
  prev="$a"
done
[ -n "$schema" ] || exit 97
[ -f "$schema" ] || exit 97
[ -n "$out" ] || exit 98
cp "$FAKE_FIXTURES/codex-last.json" "$out"
FAKE

cat > "$FAKE_BIN/agy" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "models" ]; then
  printf '%s\n' "${FAKE_GEMINI_ID}\\tGemini (fake)"
  exit 0
fi
echo agy >> "$CALL_LOG"
shared=""; prev=""
for a in "$@"; do
  [ "$prev" = "--add-dir" ] && case "$a" in */shared) shared="$a" ;; esac
  prev="$a"
done
if [ -n "${FAKE_TAMPER_SHARED:-}" ] && [ -n "$shared" ]; then
  # Record whether shared/ was writable, then tamper anyway (the owner can chmod back).
  if [ -w "$shared/target.diff" ] || [ -w "$shared" ]; then echo writable > "$FAKE_STATE_DIR/SHARED_WRITABLE"; fi
  chmod -R u+w "$shared" 2>/dev/null
  echo "tampered by a voice" >> "$shared/target.diff"
fi
if [ "${FAKE_AGY_MODE:-}" = probe ]; then echo probe > "$FAKE_PROBE_DIR/PROBE.txt"; fi
if [ "${FAKE_AGY_MODE:-}" = orphan ] && [ "$(grep -c '^agy$' "$CALL_LOG")" -eq 1 ]; then
  # Attempt 1 leaves a grandchild that ignores TERM and writes late, then fails;
  # attempt 2 (below) succeeds normally.
  bash -c 'trap "" TERM; [ -n "$3" ] && echo early > "$2/EARLY.txt"; sleep "$1"; echo late > "$2/LATE.txt"' \
    "marker-$FAKE_MARKER" "${FAKE_WRITER_DELAY:-8}" "$FAKE_PROBE_DIR" "${FAKE_EARLY_WRITE:-}" </dev/null >/dev/null 2>&1 &
  printf '%s\n' '{"status":"SUCCESS","response":"not a review"}'
  exit 0
fi
if [ "${FAKE_AGY_MODE:-}" = hang ]; then
  # A grandchild that writes into the project after a delay, plus a hanging agy.
  bash -c 'sleep "$1"; echo late > "$2/LATE.txt"' "marker-$FAKE_MARKER" "${FAKE_WRITER_DELAY:-6}" "$FAKE_PROBE_DIR" &
  if [ -n "${FAKE_EARLY_WRITE:-}" ]; then echo early > "$FAKE_PROBE_DIR/EARLY.txt"; fi
  sleep "$FAKE_MARKER"
  exit 0
fi
cat "$FAKE_FIXTURES/agy-envelope.json"
FAKE
chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/agy"

mkproj() { # fresh git repo in a directory with a space; dirty change when $1 = dirty
  rm -rf -- "$PROJ"; mkdir -p "$PROJ"
  ( cd "$PROJ" && git init -q && git symbolic-ref HEAD refs/heads/main \
    && printf 'def avg(xs):\n    return sum(xs) / len(xs)\n' > calc.py \
    && git add calc.py \
    && git -c user.name=t -c user.email=t@example.com commit -q -m init )
  if [ "${1:-}" = dirty ]; then
    printf 'def avg(xs):\n    return sum(xs) / (len(xs) - 1)\n' > "$PROJ/calc.py"
  fi
}

run_rr() { # run_rr <args...>; stdout -> $T/out, stderr -> $T/err; sets RC and RD
  : > "$CALLS"
  env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$T/tmp" \
    PEERREVIEW_CODEX_BIN="$FAKE_BIN/codex" PEERREVIEW_AGY_SYSTEM_PATHS="" \
    REVIEW_POLL_INTERVAL=1 REVIEW_MAX_ITER="${REVIEW_MAX_ITER:-60}" REVIEW_STALE_ITERS=20 \
    CALL_LOG="$CALLS" FAKE_FIXTURES="$FIX" FAKE_GEMINI_ID="$GEMINI_ID" FAKE_PROBE_DIR="$PROJ" \
    FAKE_STATE_DIR="$T" \
    bash "$RUN" "$@" > "$T/out" 2> "$T/err" < /dev/null
  RC=$?
  RD="$(sed -n '1s/^REVIEW_DIR=//p' "$T/out")"
}

# 0. is_alive must report dead/nonexistent PIDs as not alive (PID-reuse guard).
eval "$(sed -n '/^is_alive()/,/^}/p' "$RUN")"
is_alive $$ && ok "is_alive: own PID is alive" || fail "is_alive: own PID is alive"
sleep 0.1 & DEADPID=$!; wait "$DEADPID" 2>/dev/null
is_alive "$DEADPID" && fail "is_alive: reaped PID is dead" || ok "is_alive: reaped PID is dead"
is_alive 99998 && fail "is_alive: nonexistent PID is dead" || ok "is_alive: nonexistent PID is dead"

# 1. Normal run, three voices, project path with a space.
mkproj dirty
run_rr --root "$PROJ"
[ "$RC" -eq 0 ] && ok "normal run exits 0" || { fail "normal run exits 0 (rc=$RC)"; cat "$T/err" >&2; }
check "first stdout line is REVIEW_DIR=<existing dir>" test -d "$RD"
check "REVIEW_DIR carries the ownership marker" test -f "$RD/.llm-peer-review-owned"
case "$RD" in "$PROJ"/*) fail "REVIEW_DIR is outside the project" ;; *) ok "REVIEW_DIR is outside the project" ;; esac
RID="$(basename "$RD")"
check "verdicts.txt has three VALID lines" test "$(grep -c ' VALID$' "$RD/verdicts.txt")" -eq 3
check "aggregate.md has a cluster row" grep -Fq '| 1 |' "$RD/aggregate.md"
for f in snapshot.before.json snapshot.after.json target.json shared/prompt.md \
  "review_claude_${RID}.json" "review_codex_${RID}.last.md" "review_gemini_${RID}.json" \
  "review_claude_${RID}.extracted.json" "review_codex_${RID}.extracted.json" "review_gemini_${RID}.extracted.json"; do
  check "run dir has $f" test -f "$RD/$f"
done
check "all three CLIs were launched" test "$(sort -u "$CALLS" | tr '\n' ' ')" = "agy claude codex "
check "shared/ checksum was recorded" test -s "$RD/shared.sha256"
check "shared/ is writable again after the run (cleanup works)" test -w "$RD/shared"

# 2. Focus text with shell metacharacters reaches the prompt verbatim and is never executed.
mkproj dirty
FOCUS='"; touch '"$T"'/pwn; echo "'
run_rr --root "$PROJ" --focus "$FOCUS"
[ "$RC" -eq 0 ] && ok "metachar focus run exits 0" || fail "metachar focus run exits 0 (rc=$RC)"
check "focus did not execute" test ! -e "$T/pwn"
check "prompt contains the focus verbatim" grep -Fq -- "$FOCUS" "$RD/shared/prompt.md"

# 3. A reviewer that writes into the project: exit 4, no aggregate.
mkproj dirty
FAKE_AGY_MODE=probe run_rr --root "$PROJ"
[ "$RC" -eq 4 ] && ok "snapshot change exits 4" || fail "snapshot change exits 4 (rc=$RC)"
check "no aggregate.md after snapshot change" test ! -e "$RD/aggregate.md"
check "snapshot diff is reported on stderr" grep -Fq 'PROBE.txt' "$T/err"

# 3b. A voice that tampers with shared/ (other voices' inputs): exit 4, no aggregate.
mkproj dirty
rm -f "$T/SHARED_WRITABLE"
FAKE_TAMPER_SHARED=1 run_rr --root "$PROJ" --voices gemini
[ "$RC" -eq 4 ] && ok "shared/ tampering exits 4" || { fail "shared/ tampering exits 4 (rc=$RC)"; cat "$T/err" >&2; }
check "no aggregate.md after shared/ tampering" test ! -e "$RD/aggregate.md"
check "shared/ tampering is reported on stderr" grep -Fq 'shared' "$T/err"
check "shared/ was read-only while the voices ran" test ! -e "$T/SHARED_WRITABLE"

# 3c. shared/ tampering is also caught on the failure (timeout) path.
mkproj dirty
FAKE_TAMPER_SHARED=1 FAKE_AGY_MODE=hang FAKE_WRITER_DELAY=30 REVIEW_MAX_ITER=4 run_rr --root "$PROJ" --voices gemini
[ "$RC" -eq 4 ] && ok "shared/ tampering plus timeout exits 4" || { fail "shared/ tampering plus timeout exits 4 (rc=$RC)"; cat "$T/err" >&2; }
check "no fake process remains after shared/ tampering plus timeout" test -z "$(pgrep -f "marker-$FAKE_MARKER|sleep $FAKE_MARKER")"

# 3d. An attempt-1 grandchild that ignores TERM must not outlive a normal finish.
mkproj dirty
rm -f "$PROJ/LATE.txt"
START=$(date +%s)
FAKE_AGY_MODE=orphan FAKE_WRITER_DELAY=25 run_rr --root "$PROJ" --voices gemini
[ "$RC" -eq 0 ] && ok "orphaned grandchild run exits 0" || { fail "orphaned grandchild run exits 0 (rc=$RC)"; cat "$T/err" >&2; }
check "gemini ran two attempts" test "$(grep -c '^agy$' "$CALLS")" -eq 2
check "no orphaned grandchild remains after a normal finish" test -z "$(pgrep -f "marker-$FAKE_MARKER")"
while [ $(( $(date +%s) - START )) -lt 27 ]; do sleep 1; done
check "orphaned grandchild never wrote late" test ! -e "$PROJ/LATE.txt"

# 3e. The same grandchild writing BEFORE the stop: the snapshot catches it (exit 4).
mkproj dirty
FAKE_AGY_MODE=orphan FAKE_EARLY_WRITE=1 FAKE_WRITER_DELAY=30 run_rr --root "$PROJ" --voices gemini
[ "$RC" -eq 4 ] && ok "orphan early write exits 4" || { fail "orphan early write exits 4 (rc=$RC)"; cat "$T/err" >&2; }
check "orphan early write is named in the diff" grep -Fq 'EARLY.txt' "$T/err"
check "no orphaned grandchild remains after exit 4" test -z "$(pgrep -f "marker-$FAKE_MARKER")"

# 4. Claude error envelope (the fake prints a long error body: classify-review.sh
# reports bodies under 40 bytes as EMPTY, so a bare {"is_error":true} would never reach ERROR): exit 1, claude ERROR, MANGLER in the aggregate.
mkproj dirty
FAKE_CLAUDE_MODE=error run_rr --root "$PROJ"
[ "$RC" -eq 1 ] && ok "failed voice exits 1" || { fail "failed voice exits 1 (rc=$RC)"; cat "$T/err" >&2; }
check "verdicts.txt has claude ERROR" grep -Fxq 'claude ERROR' "$RD/verdicts.txt"
check "verdicts.txt keeps codex VALID" grep -Fxq 'codex VALID' "$RD/verdicts.txt"
check "aggregate.md reports MANGLER" grep -Fq 'MANGLER' "$RD/aggregate.md"

# 5. --voices codex starts only codex.
mkproj dirty
run_rr --root "$PROJ" --voices codex
[ "$RC" -eq 0 ] && ok "--voices codex exits 0" || { fail "--voices codex exits 0 (rc=$RC)"; cat "$T/err" >&2; }
check "only codex was launched" test "$(cat "$CALLS")" = "codex"
check "verdicts.txt lists only codex" test "$(cat "$RD/verdicts.txt")" = "codex VALID"
check "no gemini/claude files" test ! -e "$(ls "$RD"/review_claude_* "$RD"/review_gemini_* 2>/dev/null | head -1)"

# 5b. Watcher timeout: exit 2, verdicts.txt written, no aggregate.
mkproj dirty
FAKE_CLAUDE_MODE=hang REVIEW_MAX_ITER=3 run_rr --root "$PROJ" --voices claude
[ "$RC" -eq 2 ] && ok "watcher timeout exits 2" || fail "watcher timeout exits 2 (rc=$RC)"
check "timeout writes verdicts.txt" test -f "$RD/verdicts.txt"
check "timeout writes no aggregate.md" test ! -e "$RD/aggregate.md"
check "timeout left no hung fake process" test -z "$(pgrep -f "sleep $FAKE_MARKER")"

# 5c. Timeout stops the whole Gemini tree: the late-writing grandchild must never write.
mkproj dirty
rm -f "$PROJ/LATE.txt"
FAKE_AGY_MODE=hang FAKE_WRITER_DELAY=6 REVIEW_MAX_ITER=4 run_rr --root "$PROJ" --voices gemini
[ "$RC" -eq 2 ] && ok "gemini timeout exits 2" || { fail "gemini timeout exits 2 (rc=$RC)"; cat "$T/err" >&2; }
check "gemini timeout writes no aggregate.md" test ! -e "$RD/aggregate.md"
sleep 8
check "late write never happened" test ! -e "$PROJ/LATE.txt"
check "no fake process remains after gemini timeout" test -z "$(pgrep -f "marker-$FAKE_MARKER|sleep $FAKE_MARKER")"

# 5d. A voice that modified the project before the timeout: exit 4 outranks the timeout.
mkproj dirty
FAKE_AGY_MODE=hang FAKE_EARLY_WRITE=1 FAKE_WRITER_DELAY=30 REVIEW_MAX_ITER=4 run_rr --root "$PROJ" --voices gemini
[ "$RC" -eq 4 ] && ok "modification plus timeout exits 4" || { fail "modification plus timeout exits 4 (rc=$RC)"; cat "$T/err" >&2; }
check "exit 4 on timeout writes no aggregate.md" test ! -e "$RD/aggregate.md"
check "exit 4 diff names the written file" grep -Fq 'EARLY.txt' "$T/err"
check "no fake process remains after exit 4" test -z "$(pgrep -f "marker-$FAKE_MARKER|sleep $FAKE_MARKER")"

# 5e. SIGTERM to run-review.sh stops the voices and exits 143.
mkproj dirty
: > "$CALLS"
env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$T/tmp" PEERREVIEW_CODEX_BIN="$FAKE_BIN/codex" \
  PEERREVIEW_AGY_SYSTEM_PATHS="" REVIEW_POLL_INTERVAL=1 REVIEW_STALE_ITERS=20 CALL_LOG="$CALLS" \
  FAKE_FIXTURES="$FIX" FAKE_CLAUDE_MODE=hang \
  bash "$RUN" --root "$PROJ" --voices claude > "$T/out" 2> "$T/err" < /dev/null &
RRPID=$!
i=0; while [ "$i" -lt 20 ] && [ -z "$(pgrep -f "sleep $FAKE_MARKER")" ]; do sleep 0.5; i=$((i + 1)); done
kill -TERM "$RRPID" 2>/dev/null
wait "$RRPID"; RC=$?
[ "$RC" -eq 143 ] && ok "SIGTERM exits 143" || fail "SIGTERM exits 143 (rc=$RC)"
check "SIGTERM left no fake process" test -z "$(pgrep -f "sleep $FAKE_MARKER")"

# 6. Clean tree on main: nothing to review, exit 3.
mkproj clean
run_rr --root "$PROJ"
[ "$RC" -eq 3 ] && ok "clean tree exits 3" || fail "clean tree exits 3 (rc=$RC)"
check "no voice started on a clean tree" test ! -s "$CALLS"

# 7. Wiring errors exit 2 before any voice starts.
mkproj dirty
run_rr --root "$PROJ" --voices claude,bogus
[ "$RC" -eq 2 ] && ok "unknown voice exits 2" || fail "unknown voice exits 2 (rc=$RC)"
check "unknown voice starts nothing" test ! -s "$CALLS"
run_rr --root "$PROJ" --nonsense
[ "$RC" -eq 2 ] && ok "unknown option exits 2" || fail "unknown option exits 2 (rc=$RC)"
run_rr --root "$T/does-not-exist"
[ "$RC" -eq 2 ] && ok "missing root exits 2" || fail "missing root exits 2 (rc=$RC)"
# preflight failure: unusable Codex override
: > "$CALLS"
env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$T/tmp" PEERREVIEW_CODEX_BIN="$T/nope/codex" \
  PEERREVIEW_AGY_SYSTEM_PATHS="" CALL_LOG="$CALLS" FAKE_FIXTURES="$FIX" \
  bash "$RUN" --root "$PROJ" > "$T/out" 2> "$T/err" < /dev/null
RC=$?
[ "$RC" -eq 2 ] && ok "preflight failure exits 2" || fail "preflight failure exits 2 (rc=$RC)"
check "preflight failure starts no voice" test ! -s "$CALLS"
# preflight only checks selected voices: broken codex does not block --voices claude
env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$T/tmp" PEERREVIEW_CODEX_BIN="$T/nope/codex" \
  PEERREVIEW_AGY_SYSTEM_PATHS="" REVIEW_POLL_INTERVAL=1 REVIEW_STALE_ITERS=20 \
  CALL_LOG="$CALLS" FAKE_FIXTURES="$FIX" \
  bash "$RUN" --root "$PROJ" --voices claude > "$T/out" 2> "$T/err" < /dev/null
RC=$?
[ "$RC" -eq 0 ] && ok "preflight ignores unselected voices" || { fail "preflight ignores unselected voices (rc=$RC)"; cat "$T/err" >&2; }
# REVIEW_DIR inside the project is refused
mkdir -p "$PROJ/tmp"
: > "$CALLS"
env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$PROJ/tmp" PEERREVIEW_CODEX_BIN="$FAKE_BIN/codex" \
  PEERREVIEW_AGY_SYSTEM_PATHS="" CALL_LOG="$CALLS" FAKE_FIXTURES="$FIX" \
  bash "$RUN" --root "$PROJ" > "$T/out" 2> "$T/err" < /dev/null
RC=$?
[ "$RC" -eq 2 ] && ok "REVIEW_DIR inside project exits 2" || fail "REVIEW_DIR inside project exits 2 (rc=$RC)"
check "REVIEW_DIR inside project starts no voice" test ! -s "$CALLS"

# Relative PATH entries must not let the reviewed project supply a CLI.
mkproj dirty
mkdir -p "$PROJ/bin"
printf '#!/bin/bash\necho project-claude >> "$CALL_LOG"\nexit 0\n' > "$PROJ/bin/claude"
chmod +x "$PROJ/bin/claude"
: > "$CALLS"
( cd "$PROJ" && env PATH="bin:.:$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$T/tmp" \
    PEERREVIEW_CODEX_BIN="$FAKE_BIN/codex" PEERREVIEW_AGY_SYSTEM_PATHS="" \
    REVIEW_POLL_INTERVAL=1 REVIEW_STALE_ITERS=20 CALL_LOG="$CALLS" FAKE_FIXTURES="$FIX" \
    bash "$RUN" --root . --voices claude > "$T/out" 2> "$T/err" < /dev/null )
RC=$?
[ "$RC" -eq 0 ] && ok "relative PATH run exits 0" || { fail "relative PATH run exits 0 (rc=$RC)"; cat "$T/err" >&2; }
check "relative PATH entry cannot supply claude from the project" test -z "$(grep project-claude "$CALLS")"
rm -rf -- "$PROJ/bin"

# Final assertion: this test run must leave no fake process behind.
sleep 1
check "no fake process of this run remains" test -z "$(pgrep -f "$LEFTOVER_RE")"

if [ "$FAILS" -ne 0 ]; then printf '%s check(s) failed\n' "$FAILS" >&2; exit 1; fi
echo 'ok - run-review.sh end-to-end'
