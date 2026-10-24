#!/bin/bash
# wait-for-reviewers.sh - smart polling watcher for llm-peer-review-skill.
#
# Usage:
#   wait-for-reviewers.sh <RID> <CLAUDE_PID> <CODEX_PID> <GEMINI_PID>
#
# Args may be 0 for processes that aren't being run this round (e.g. if you
# only need Claude+Codex this run, pass 0 for GEMINI_PID and the watcher
# treats that slot as already done).
#
# Why this script instead of `wait` or naïve `pgrep`-loop:
#
# 1. PID-based check via `kill -0` - sends NO signal, only tests if PID
#    exists. The watcher can NEVER false-positive on itself because the PID
#    list is static and known at launch (unlike `pgrep -f "<pattern>"` which
#    can match the watcher's own command-line if the pattern appears as an
#    argument, causing the loop to wait forever on itself).
#
# 2. Scans output files for known error patterns (429, RESOURCE_EXHAUSTED,
#    ModelNotFoundError, etc.) so a CLI that exits with an error response
#    body is detected - the parent (controller) doesn't have to read each
#    file manually to know if the review actually succeeded.
#
# 3. 10s poll interval gives finer-grained progress visibility than `wait`
#    (which is binary: alive vs done). The per-iteration log line shows
#    file growth + error counts in near-real-time.
#
# 4. Hard timeout (35 min default) prevents infinite hangs if a CLI gets
#    stuck mid-stream.
#
# 5. Early-warning if a process exits with only error-output (<5KB) AND
#    error patterns detected - visible in the log without waiting for the
#    full session to time out.
#
# 6. False-done guard (added after a real incident): a NON-skipped slot is
#    only declared "done" once it has actually been SEEN running at least
#    once (or finished with stable output before the first poll). Passing an
#    empty/0/wrong PID for a process that should be running no longer silently
#    reports "all done" - it raises a wiring error instead. See $STALE_ITERS.
#
# Output format (one line per iteration, every 10s):
#   [HH:MM:SS i<N>] claude=running 0B err=0 | codex=done 1MB err=0 | gemini=done 4.7KB err=2
#
# Exit codes:
#   0   - all (non-skipped) reviewers produced a usable VALID or CLEAN review
#   1   - at least one reviewer did NOT produce a usable review: error patterns,
#         a MISFIRE (Claude roleplayed the orchestrator), a CAPACITY/auth
#         failure (Gemini), or WEAK/EMPTY output. Read the "Verdicts:" line and
#         relaunch / fall back - never count a non-VALID reviewer's silence as
#         agreement. (Needs classify-review.sh beside this script; without it,
#         exit 1 falls back to its old meaning "error patterns seen".)
#   2   - wiring error: no PIDs to watch, a non-integer PID, or a non-skipped
#         slot was never observed running (likely a wrong/empty PID arg)
#   124 - 35 min hard timeout reached

set -u
RID="${1:?Usage: $0 <RID> <CLAUDE_PID> <CODEX_PID> <GEMINI_PID>}"
CLAUDE_PID="${2:-0}"
CODEX_PID="${3:-0}"
GEMINI_PID="${4:-0}"
case "$RID" in
  *[!A-Za-z0-9._-]*) echo "ERROR: bad RID (allowed: A-Za-z0-9._-): $RID" >&2; exit 2 ;;
esac

# --- Validate PID args are non-negative integers (catches empty / garbled args) ---
validate_pid() {
  local name="$1" pid="$2"
  case "$pid" in
    ''|*[!0-9]*)
      echo "ERROR: $name PID arg is not a non-negative integer: '$pid'" >&2
      echo "       Pass the PID captured at launch, or 0 to skip this slot." >&2
      exit 2
      ;;
  esac
}
validate_pid CLAUDE "$CLAUDE_PID"
validate_pid CODEX  "$CODEX_PID"
validate_pid GEMINI "$GEMINI_PID"

# All-zero means nothing to watch - almost always a wiring mistake (e.g. the
# PID file failed to load and $1/$2/$3 expanded empty). Fail loudly instead of
# printing a misleading "all done".
if [ "$CLAUDE_PID" = "0" ] && [ "$CODEX_PID" = "0" ] && [ "$GEMINI_PID" = "0" ]; then
  echo "ERROR: all three PIDs are 0 - nothing to watch." >&2
  echo "       Did the PID-capture/file-load step fail before calling the watcher?" >&2
  exit 2
fi

# Output file paths - must match what the launching shell wrote to.
# NOTE: the three slots do not share one format. Claude emits a JSON envelope,
# Gemini emits markdown into its legacy .json filename, and native Codex emits a
# markdown last-message file. classify-review.sh handles all three via content.
REVIEW_ROOT="${REVIEW_DIR:?wait-for-reviewers requires a private REVIEW_DIR}"
[ -d "$REVIEW_ROOT" ] || { echo "ERROR: REVIEW_DIR does not exist: $REVIEW_ROOT" >&2; exit 2; }
CLAUDE_FILE="$REVIEW_ROOT/review_claude_${RID}.json"
CODEX_FILE="$REVIEW_ROOT/review_codex_${RID}.last.md"
GEMINI_FILE="$REVIEW_ROOT/review_gemini_${RID}.json"

# Optional richer per-reviewer verdicts (VALID/MISFIRE/CAPACITY/ERROR/WEAK/EMPTY)
# via the sibling helper. If present it drives the verdicts + exit code below;
# if absent we fall back to the raw ERROR_RE heuristic only.
HAVE_CLASSIFY=0
_WATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLASSIFY_SH lets a caller point the watcher at a content-appropriate classifier
# that defines classify_review() - e.g. the triplealtreview doc-review skill ships
# a doc-aware classifier (VALID keys on quoted-claim + file/section, not file:line).
# Defaults to the sibling code classifier, so existing llm-peer-review behaviour is
# fully unchanged.
_CLASSIFY_SH="${CLASSIFY_SH:-$_WATCH_DIR/classify-review.sh}"
if [ -f "$_CLASSIFY_SH" ]; then
  # shellcheck source=/dev/null
  . "$_CLASSIFY_SH" && HAVE_CLASSIFY=1
fi

# Error patterns to scan output for. Tuned for Claude/Gemini/Codex error
# responses; extend as new failure modes are discovered. (2026-06: added the
# Gemini Code-Assist oauth-path failures - fetchAdminControls / GaxiosError /
# TerminalQuotaError / loadCodeAssist / retrieveUserQuota - and the Claude
# headless error envelope, so the early-warning catches them too.)
# (2026-06-10: added CCS-proxy failure modes - ConnectionRefused / "Unable to
# connect to API" / non-null api_error_status.)
# (2026-06-19: gemini now runs via `agy` (Antigravity CLI), not ccs. These
# patterns are ADVISORY only - the verdict comes from classify-review.sh, which
# scores agy's plain-markdown on file:line. agy-specific error strings are not
# all enumerated here; a failed agy run lands as WEAK/EMPTY → .SKIPPED anyway.)
ERROR_RE='429|RESOURCE_EXHAUSTED|UNAVAILABLE|ModelNotFoundError|"code": *(404|429|500|503)|Error: Input must|Error executing|"error": *\{|fetchAdminControls|GaxiosError|TerminalQuotaError|exhausted your (capacity|quota)|loadCodeAssist|retrieveUserQuota|service is currently unavailable|overloaded_error|insufficient_quota|error_during_execution|error_max_structured_output_retries|"is_error": *true|Unable to connect to API|ConnectionRefused|ECONNREFUSED|token invalidated|not logged in|please .*sign in|unauthorized|"api_error_status": *[45][0-9][0-9]'

POLL_INTERVAL="${REVIEW_POLL_INTERVAL:-10}"
MAX_ITER="${REVIEW_MAX_ITER:-210}"     # default: 210 × 10s = 35 min hard cap
STALE_ITERS="${REVIEW_STALE_ITERS:-6}" # default: 6 × 10s = 60s wiring guard
for n in "$POLL_INTERVAL" "$MAX_ITER" "$STALE_ITERS"; do
  case "$n" in ''|*[!0-9]*|0) echo "ERROR: watcher timing values must be positive integers" >&2; exit 2 ;; esac
done

# Helper: kill -0 returns 0 if PID exists, non-zero otherwise.
# PID=0 means "this slot is skipped" and is treated as already done.
is_running() {
  local pid="$1"
  [ "$pid" = "0" ] && return 1
  kill -0 "$pid" 2>/dev/null
}

# Helper: byte-size of a file, always a single integer (0 if missing).
file_size() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  local n
  n=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  [ -z "$n" ] && n=0
  echo "$n"
}

# Helper: count error-pattern matches, always a single integer.
# NB: `grep -c` prints "0" AND exits 1 when there are no matches. The old code
# used `grep -cE ... || echo 0`, which appended a SECOND "0" on the no-match
# exit-1, producing "0\n0" and breaking every `[ "$n" -gt 0 ]` test downstream.
# Capturing the single line of stdout (and ignoring the exit code) is correct.
count_errors() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  local n
  n=$(grep -cE "$ERROR_RE" -- "$f" 2>/dev/null)
  [ -z "$n" ] && n=0
  echo "$n"
}

# Helper: human-readable byte count (B, KB, MB)
human_size() {
  local n="$1"
  if [ -z "$n" ] || [ "$n" -eq 0 ]; then echo "0B"
  elif [ "$n" -lt 1024 ]; then echo "${n}B"
  elif [ "$n" -lt 1048576 ]; then echo "$((n / 1024))KB"
  else echo "$((n / 1048576))MB"
  fi
}

# Per-slot "effective state" with a seen-running latch.
#   $1 = pid   $2 = seen_running latch (0/1)   $3 = cur size   $4 = prev size
# Echoes one of: skipped | running | done | pending
# - skipped : explicit PID 0 (intended not-run slot) -> counts as done
# - running : PID currently alive (latch should be set by caller)
# - done    : was seen running and is now gone, OR finished with stable
#             non-empty output before we ever polled it alive
# - pending : non-skipped PID not alive AND never seen running AND no stable
#             output yet -> NOT done; likely starting up or a wrong PID
slot_state() {
  local pid="$1" seen="$2" size="$3" prev="$4"
  if [ "$pid" = "0" ]; then echo skipped; return; fi
  if is_running "$pid"; then echo running; return; fi
  if [ "$seen" = "1" ]; then echo done; return; fi
  # never seen running and not running now:
  if [ "$size" -gt 0 ] && [ "$size" = "$prev" ]; then echo done; return; fi
  echo pending
}

ITER=0
SAW_ERROR=0
WARNED_CLAUDE=0
WARNED_CODEX=0
WARNED_GEMINI=0

SEEN_CLAUDE=0
SEEN_CODEX=0
SEEN_GEMINI=0

# Per-reviewer verdict (set once when a slot first reaches "done").
CLASS_CLAUDE=""
CLASS_CODEX=""
CLASS_GEMINI=""

C_PREV=-1
X_PREV=-1
G_PREV=-1

PEND_CLAUDE=0
PEND_CODEX=0
PEND_GEMINI=0

while [ $ITER -lt $MAX_ITER ]; do
  ITER=$((ITER + 1))
  TS=$(date +%H:%M:%S)

  # File-sizes first (state logic depends on them).
  C_SIZE=$(file_size "$CLAUDE_FILE")
  X_SIZE=$(file_size "$CODEX_FILE")
  G_SIZE=$(file_size "$GEMINI_FILE")

  # Latch "seen running" the moment a PID is observed alive.
  is_running "$CLAUDE_PID" && SEEN_CLAUDE=1
  is_running "$CODEX_PID"  && SEEN_CODEX=1
  is_running "$GEMINI_PID" && SEEN_GEMINI=1

  C_STATE=$(slot_state "$CLAUDE_PID" "$SEEN_CLAUDE" "$C_SIZE" "$C_PREV")
  X_STATE=$(slot_state "$CODEX_PID"  "$SEEN_CODEX"  "$X_SIZE" "$X_PREV")
  G_STATE=$(slot_state "$GEMINI_PID" "$SEEN_GEMINI" "$G_SIZE" "$G_PREV")

  # Error-counts (always single integers)
  C_ERR=$(count_errors "$CLAUDE_FILE")
  X_ERR=$(count_errors "$CODEX_FILE")
  G_ERR=$(count_errors "$GEMINI_FILE")

  printf '[%s i%d] claude=%s %s err=%s | codex=%s %s err=%s | gemini=%s %s err=%s\n' \
    "$TS" "$ITER" \
    "$C_STATE" "$(human_size "$C_SIZE")" "$C_ERR" \
    "$X_STATE" "$(human_size "$X_SIZE")" "$X_ERR" \
    "$G_STATE" "$(human_size "$G_SIZE")" "$G_ERR"

  # Track how long a non-skipped slot stays "pending" (never seen running, no
  # stable output). Persisting past STALE_ITERS means the PID is almost
  # certainly wrong/empty - fail loudly rather than wait 35 min or lie "done".
  [ "$C_STATE" = "pending" ] && PEND_CLAUDE=$((PEND_CLAUDE + 1)) || PEND_CLAUDE=0
  [ "$X_STATE" = "pending" ] && PEND_CODEX=$((PEND_CODEX + 1))   || PEND_CODEX=0
  [ "$G_STATE" = "pending" ] && PEND_GEMINI=$((PEND_GEMINI + 1)) || PEND_GEMINI=0

  if [ "$PEND_CLAUDE" -ge "$STALE_ITERS" ] || [ "$PEND_CODEX" -ge "$STALE_ITERS" ] || [ "$PEND_GEMINI" -ge "$STALE_ITERS" ]; then
    echo "" >&2
    echo "ERROR: a reviewer slot was never observed running and produced no output after $((STALE_ITERS * POLL_INTERVAL))s." >&2
    echo "       claude(pid=$CLAUDE_PID)=$C_STATE codex(pid=$CODEX_PID)=$X_STATE gemini(pid=$GEMINI_PID)=$G_STATE" >&2
    echo "       Likely a wrong/empty PID arg, or the process was launched in a shell that already exited." >&2
    echo "       Verify with: ps -p <pid>  /  pgrep -fl 'claude -p|agy|codex'  before relaunching." >&2
    exit 2
  fi

  # Early-warning if a process exited with only error-output (<5KB) AND
  # error patterns detected. Warn ONCE per process so the log doesn't spam.
  if [ "$C_STATE" = "done" ] && [ "$WARNED_CLAUDE" = "0" ] && [ "$C_ERR" -gt 0 ] && [ "$C_SIZE" -lt 5000 ]; then
    echo "WARN: Claude exited with error-output (${C_SIZE}B, $C_ERR error patterns)" >&2
    tail -10 "$CLAUDE_FILE" >&2
    WARNED_CLAUDE=1
    SAW_ERROR=1
  fi
  if [ "$X_STATE" = "done" ] && [ "$WARNED_CODEX" = "0" ] && [ "$X_ERR" -gt 0 ] && [ "$X_SIZE" -lt 5000 ]; then
    echo "WARN: Codex exited with error-output (${X_SIZE}B, $X_ERR error patterns)" >&2
    tail -10 "$CODEX_FILE" >&2
    WARNED_CODEX=1
    SAW_ERROR=1
  fi
  if [ "$G_STATE" = "done" ] && [ "$WARNED_GEMINI" = "0" ] && [ "$G_ERR" -gt 0 ] && [ "$G_SIZE" -lt 5000 ]; then
    echo "WARN: Gemini exited with error-output (${G_SIZE}B, $G_ERR error patterns)" >&2
    tail -10 "$GEMINI_FILE" >&2
    WARNED_GEMINI=1
    SAW_ERROR=1
  fi

  # Verdict-based early warning (classify each slot ONCE on reaching "done").
  # Catches the failures the size+error heuristic above misses - above all a
  # roleplay MISFIRE, which carries NO error pattern and is often >5KB.
  if [ "$HAVE_CLASSIFY" = "1" ]; then
    if [ "$C_STATE" = "done" ] && [ -z "$CLASS_CLAUDE" ]; then
      CLASS_CLAUDE=$(classify_review "$CLAUDE_FILE" 2>/dev/null)
      if [ "$CLASS_CLAUDE" != "VALID" ] && [ "$CLASS_CLAUDE" != "CLEAN" ]; then
        echo "WARN: claude produced no usable review (verdict=$CLASS_CLAUDE) - relaunch once (SKILL.md §4)" >&2
        tail -6 "$CLAUDE_FILE" >&2; SAW_ERROR=1
      fi
    fi
    if [ "$X_STATE" = "done" ] && [ -z "$CLASS_CODEX" ]; then
      CLASS_CODEX=$(classify_review "$CODEX_FILE" 2>/dev/null)
      [ "$CLASS_CODEX" != "VALID" ] && [ "$CLASS_CODEX" != "CLEAN" ] && { echo "WARN: codex produced no usable review (verdict=$CLASS_CODEX)" >&2; SAW_ERROR=1; }
    fi
    if [ "$G_STATE" = "done" ] && [ -z "$CLASS_GEMINI" ]; then
      CLASS_GEMINI=$(classify_review "$GEMINI_FILE" 2>/dev/null)
      [ "$CLASS_GEMINI" != "VALID" ] && [ "$CLASS_GEMINI" != "CLEAN" ] && { echo "WARN: gemini produced no usable review (verdict=$CLASS_GEMINI) - check agy auth/model ('agy models') + network, then relaunch once" >&2; SAW_ERROR=1; }
    fi
  fi

  # All done? "skipped" and "done" both count as terminal; "running"/"pending" do not.
  is_terminal() { [ "$1" = "done" ] || [ "$1" = "skipped" ]; }
  if is_terminal "$C_STATE" && is_terminal "$X_STATE" && is_terminal "$G_STATE"; then
    echo ""
    echo "=== Alle ${ITER} × ${POLL_INTERVAL}s = $((ITER * POLL_INTERVAL))s - alle processer afsluttet ==="
    echo ""
    echo "Final sizes: claude=$(human_size "$C_SIZE") codex=$(human_size "$X_SIZE") gemini=$(human_size "$G_SIZE")"

    NOT_VALID=0
    if [ "$HAVE_CLASSIFY" = "1" ]; then
      # classify any slot not already classified (e.g. finished before first poll)
      [ "$C_STATE" = "done" ] && [ -z "$CLASS_CLAUDE" ] && CLASS_CLAUDE=$(classify_review "$CLAUDE_FILE" 2>/dev/null)
      [ "$X_STATE" = "done" ] && [ -z "$CLASS_CODEX" ]  && CLASS_CODEX=$(classify_review "$CODEX_FILE" 2>/dev/null)
      [ "$G_STATE" = "done" ] && [ -z "$CLASS_GEMINI" ] && CLASS_GEMINI=$(classify_review "$GEMINI_FILE" 2>/dev/null)
      [ "$C_STATE" = "skipped" ] && CLASS_CLAUDE="SKIPPED"
      [ "$X_STATE" = "skipped" ] && CLASS_CODEX="SKIPPED"
      [ "$G_STATE" = "skipped" ] && CLASS_GEMINI="SKIPPED"
      echo "Verdicts: claude=${CLASS_CLAUDE:-?} codex=${CLASS_CODEX:-?} gemini=${CLASS_GEMINI:-?}"
      echo "  VALID/CLEAN=use · MISFIRE=relaunch · CAPACITY=check auth/network/quota · WEAK/EMPTY/ERROR=inspect/retry · SKIPPED=not run"
      for c in "$CLASS_CLAUDE" "$CLASS_CODEX" "$CLASS_GEMINI"; do
        case "$c" in VALID|CLEAN|SKIPPED|"") ;; *) NOT_VALID=1 ;; esac
      done
    fi

    # Exit-code decision (review 2026-06-10, claude+codex consensus finding):
    # when the classifier is available, the VERDICTS decide - raw ERROR_RE hits
    # are advisory only. ERROR_RE matches bare substrings (e.g. "429" inside
    # "duration_ms": 84293, or quoted error-handling strings in review prose),
    # so a short VALID review could otherwise force a false exit 1 and trigger
    # pointless relaunches. Without the classifier, fall back to SAW_ERROR.
    FAILED=0
    if [ "$HAVE_CLASSIFY" = "1" ]; then
      FAILED=$NOT_VALID
      [ "$SAW_ERROR" = "1" ] && [ "$NOT_VALID" = "0" ] && \
        echo "NOTE: raw error patterns were seen but all verdicts are VALID - treating as quoted prose, not failure."
    else
      FAILED=$SAW_ERROR
    fi
    if [ "$FAILED" = "1" ]; then
      echo "Final error counts: claude=$C_ERR codex=$X_ERR gemini=$G_ERR"
      echo "Exit code 1 - at least one reviewer did NOT produce a usable (VALID/CLEAN) review."
      echo "Do NOT treat a non-VALID reviewer's silence as 'found nothing' / agreement;"
      echo "relaunch (MISFIRE) or fall back (CAPACITY) per the verdicts above."
      exit 1
    fi
    exit 0
  fi

  C_PREV=$C_SIZE
  X_PREV=$X_SIZE
  G_PREV=$G_SIZE

  sleep "$POLL_INTERVAL"
done

# Timeout reached. Only kill slots that were NOT already terminal at the last
# poll: an early-finished reviewer's PID may have been reused by the OS for an
# unrelated process by now (review 2026-06-10) - killing it blind is a PID-reuse
# race. ${C_STATE:-} guards first-iteration edge (loop always runs once, but
# stay safe under set -u).
echo ""
echo "TIMEOUT after $((MAX_ITER * POLL_INTERVAL))s - killing still-running reviewer PIDs"
[ "$CLAUDE_PID" != "0" ] && [ "${C_STATE:-running}" != "done" ] && [ "${C_STATE:-running}" != "skipped" ] && kill "$CLAUDE_PID" 2>/dev/null
[ "$CODEX_PID" != "0" ] && [ "${X_STATE:-running}" != "done" ] && [ "${X_STATE:-running}" != "skipped" ] && kill "$CODEX_PID" 2>/dev/null
[ "$GEMINI_PID" != "0" ] && [ "${G_STATE:-running}" != "done" ] && [ "${G_STATE:-running}" != "skipped" ] && kill "$GEMINI_PID" 2>/dev/null
exit 124
