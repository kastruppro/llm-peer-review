#!/bin/bash
# run-review.sh - the single entry point of llm-peer-review.
#
# Usage:
#   run-review.sh [--root DIR] [--scope auto|working-tree|branch|full] [--base REF]
#                 [--adversarial] [--focus TEXT] [--voices claude,gemini,codex]
#
# Flow: preflight (selected voices only) -> private run dir -> prepare shared
# inputs -> snapshot before -> launch voices in parallel -> watch -> snapshot
# after -> extract, classify, aggregate. The first stdout line is REVIEW_DIR=<path>.
# The run directory is never deleted by this script.
#
# Exit codes:
#   0  every selected voice is VALID/CLEAN
#   1  at least one selected voice is missing/invalid; aggregate.md is written
#   2  preflight, wiring, watcher failure or watcher timeout (no aggregate)
#   3  nothing to review (from prepare_review.py)
#   4  the project changed while the reviewers ran (snapshot diff; no aggregate)
#
# Watcher timing knobs (env): REVIEW_POLL_INTERVAL, REVIEW_MAX_ITER, REVIEW_STALE_ITERS.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../schemas/review-output.schema.json"

die() { echo "run-review: $*" >&2; exit 2; }

usage() {
  echo "usage: run-review.sh [--root DIR] [--scope auto|working-tree|branch|full] [--base REF] [--adversarial] [--focus TEXT] [--voices claude,gemini,codex]" >&2
  exit 2
}

# --- Arguments ---------------------------------------------------------------
ROOT="$(pwd -P)"
SCOPE=auto
BASE=""
ADVERSARIAL=0
FOCUS=""
VOICES="claude,gemini,codex"
while [ $# -gt 0 ]; do
  case "$1" in
    --adversarial) ADVERSARIAL=1; shift ;;
    --root|--scope|--base|--focus|--voices)
      [ $# -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --root) ROOT="$2" ;;
        --scope) SCOPE="$2" ;;
        --base) BASE="$2" ;;
        --focus) FOCUS="$2" ;;
        --voices) VOICES="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage ;;
    *) echo "run-review: unknown argument: $1" >&2; usage ;;
  esac
done

WANT_CLAUDE=0; WANT_GEMINI=0; WANT_CODEX=0
OLD_IFS="$IFS"; IFS=','
for v in $VOICES; do
  case "$v" in
    claude) WANT_CLAUDE=1 ;;
    gemini) WANT_GEMINI=1 ;;
    codex)  WANT_CODEX=1 ;;
    *) IFS="$OLD_IFS"; die "unknown voice '$v' (allowed: claude, gemini, codex)" ;;
  esac
done
IFS="$OLD_IFS"
[ $((WANT_CLAUDE + WANT_GEMINI + WANT_CODEX)) -gt 0 ] || die "--voices selected no voice"

PROJECT_ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || die "--root is not a directory: $ROOT"

# --- Preflight (selected voices only; nothing is started yet) ----------------
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v git >/dev/null 2>&1 || die "git not found"
[ -f "$SCHEMA" ] || die "schema not found: $SCHEMA"
bash "$SCRIPT_DIR/models.sh" check >/dev/null || die "models.sh check failed"

CLAUDE_MODEL=""; CLAUDE_EFFORT=""; GEMINI_MODEL=""; AGY_BIN=""
CODEX_MODEL=""; CODEX_EFFORT=""; CODEX_BIN=""
if [ "$WANT_CLAUDE" -eq 1 ]; then
  command -v claude >/dev/null 2>&1 || die "claude CLI not found"
  CLAUDE_MODEL="$(bash "$SCRIPT_DIR/models.sh" claude model)" || die "no Claude model"
  CLAUDE_EFFORT="$(bash "$SCRIPT_DIR/models.sh" claude effort)" || die "no Claude effort"
fi
if [ "$WANT_GEMINI" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || die "jq not found (needed for the Gemini voice)"
  AGY_BIN="$(bash "$SCRIPT_DIR/preflight.sh" agy-path)" || exit 2
  if [ -z "${ANTIGRAVITY_API_KEY:-}" ] && [ ! -d "${HOME:-/nonexistent}/.gemini/antigravity-cli" ]; then
    die "agy is not authenticated: set ANTIGRAVITY_API_KEY or sign in once with agy"
  fi
  GEMINI_MODEL="$(bash "$SCRIPT_DIR/models.sh" gemini model)" || die "no Gemini model"
fi
if [ "$WANT_CODEX" -eq 1 ]; then
  CODEX_MODEL="$(bash "$SCRIPT_DIR/models.sh" codex model)" || die "no Codex model"
  CODEX_EFFORT="$(bash "$SCRIPT_DIR/models.sh" codex effort)" || die "no Codex effort"
  CODEX_BIN="$(python3 -I "$SCRIPT_DIR/resolve-codex.py")" || die "no compatible Codex CLI"
  [ -n "$CODEX_BIN" ] || die "no compatible Codex CLI"
fi

# --- Private run directory ---------------------------------------------------
umask 077
REVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review.XXXXXX")" || die "mktemp failed"
REVIEW_DIR="$(cd "$REVIEW_DIR" && pwd -P)" || die "run directory unreadable"
RID="$(basename "$REVIEW_DIR")"
case "$REVIEW_DIR/" in
  "$PROJECT_ROOT"/*) echo "run-review: run directory $REVIEW_DIR is inside the project; set TMPDIR outside $PROJECT_ROOT" >&2
                     rmdir "$REVIEW_DIR" 2>/dev/null; exit 2 ;;
esac
export REVIEW_DIR
touch "$REVIEW_DIR/.llm-peer-review-owned" || die "cannot write to $REVIEW_DIR"
printf 'REVIEW_DIR=%s\n' "$REVIEW_DIR"
printf 'REVIEW_RUN_ID=%s\n' "$RID"

# --- Shared inputs -----------------------------------------------------------
PREP=(python3 -I "$SCRIPT_DIR/prepare_review.py" --root "$PROJECT_ROOT" --out "$REVIEW_DIR/shared" --scope "$SCOPE")
[ -n "$BASE" ] && PREP+=(--base "$BASE")
[ "$ADVERSARIAL" -eq 1 ] && PREP+=(--adversarial)
[ -n "$FOCUS" ] && PREP+=(--focus "$FOCUS")
LABEL="$("${PREP[@]}")"
PREP_RC=$?
case "$PREP_RC" in
  0) ;;
  3) exit 3 ;;
  *) exit 2 ;;
esac
printf 'TARGET=%s\n' "$LABEL"
cp "$REVIEW_DIR/shared/prompt.md" "$REVIEW_DIR/prompt.md"
cp "$REVIEW_DIR/shared/target.json" "$REVIEW_DIR/target.json"
PROMPT="$(cat "$REVIEW_DIR/shared/prompt.md")"

python3 -I "$SCRIPT_DIR/snapshot.py" "$PROJECT_ROOT" > "$REVIEW_DIR/snapshot.before.json" \
  || die "snapshot before the review failed"

# --- Launch the selected voices in parallel ----------------------------------
CLAUDE_PID=0; CODEX_PID=0; GEMINI_PID=0
CLAUDE_SYSTEM="You are one standalone code reviewer, not an orchestrator. Read the code yourself. Never launch agents or other reviewers. Never modify files. Return only concrete review findings with file:line evidence."

if [ "$WANT_CLAUDE" -eq 1 ]; then
  (
    cd "$PROJECT_ROOT" || exit 2
    CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 exec claude -p \
      --model "$CLAUDE_MODEL" \
      --effort "$CLAUDE_EFFORT" \
      --setting-sources user \
      --tools "Read,Glob,Grep" \
      --disallowedTools "Agent" "Task" \
      --permission-mode dontAsk \
      --add-dir "$REVIEW_DIR/shared" \
      --system-prompt "$CLAUDE_SYSTEM" \
      --json-schema "$(cat "$SCHEMA")" \
      --output-format json \
      "$PROMPT"
  ) </dev/null \
    > "$REVIEW_DIR/review_claude_${RID}.json" \
    2> "$REVIEW_DIR/review_claude_${RID}.err" &
  CLAUDE_PID=$!
fi

if [ "$WANT_GEMINI" -eq 1 ]; then
  AGY_BIN="$AGY_BIN" GEMINI_REVIEW_MODEL="$GEMINI_MODEL" \
    "$SCRIPT_DIR/gemini-review.sh" "$RID" "$PROMPT" "$PROJECT_ROOT" \
    </dev/null > "$REVIEW_DIR/gemini-wrapper.log" 2>&1 &
  GEMINI_PID=$!
fi

if [ "$WANT_CODEX" -eq 1 ]; then
  "$CODEX_BIN" exec \
    --ignore-user-config \
    --model "$CODEX_MODEL" \
    -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
    -c project_doc_max_bytes=0 \
    --sandbox read-only \
    --skip-git-repo-check \
    --cd "$PROJECT_ROOT" \
    --color never \
    --output-schema "$SCHEMA" \
    --output-last-message "$REVIEW_DIR/review_codex_${RID}.last.md" \
    "$PROMPT" \
    </dev/null \
    > "$REVIEW_DIR/review_codex_${RID}.out" \
    2> "$REVIEW_DIR/review_codex_${RID}.err" &
  CODEX_PID=$!
fi

# --- Wait --------------------------------------------------------------------
"$SCRIPT_DIR/wait-for-reviewers.sh" "$RID" "$CLAUDE_PID" "$CODEX_PID" "$GEMINI_PID"
WATCH_RC=$?
printf 'watcher exit=%s\n' "$WATCH_RC"

voice_file() { # voice_file <voice> -> the published output path the watcher expects
  case "$1" in
    claude) printf '%s\n' "$REVIEW_DIR/review_claude_${RID}.json" ;;
    gemini) printf '%s\n' "$REVIEW_DIR/review_gemini_${RID}.json" ;;
    codex)  printf '%s\n' "$REVIEW_DIR/review_codex_${RID}.last.md" ;;
  esac
}

SELECTED=""
[ "$WANT_CLAUDE" -eq 1 ] && SELECTED="$SELECTED claude"
[ "$WANT_GEMINI" -eq 1 ] && SELECTED="$SELECTED gemini"
[ "$WANT_CODEX" -eq 1 ] && SELECTED="$SELECTED codex"

write_verdicts() {
  : > "$REVIEW_DIR/verdicts.txt"
  local v f cls
  for v in $SELECTED; do
    f="$(voice_file "$v")"
    cls="$(bash "$SCRIPT_DIR/classify-review.sh" "$f" 2>/dev/null | tail -n 1)"
    printf '%s %s\n' "$v" "${cls:-WEAK}" >> "$REVIEW_DIR/verdicts.txt"
  done
}

case "$WATCH_RC" in
  0|1) ;;
  *)
    # Wiring error or timeout: stop what still runs, record what exists, no aggregate.
    for p in $CLAUDE_PID $CODEX_PID $GEMINI_PID; do
      [ "$p" != "0" ] && kill "$p" 2>/dev/null
    done
    write_verdicts
    echo "run-review: watcher failed (exit $WATCH_RC); no aggregate written" >&2
    exit 2
    ;;
esac

# --- Read-only invariant -----------------------------------------------------
python3 -I "$SCRIPT_DIR/snapshot.py" "$PROJECT_ROOT" > "$REVIEW_DIR/snapshot.after.json" \
  || die "snapshot after the review failed"
if ! diff -u "$REVIEW_DIR/snapshot.before.json" "$REVIEW_DIR/snapshot.after.json" >&2; then
  echo "run-review: the project changed while the reviewers ran (see the diff above); no aggregate written. Re-run on a stable snapshot." >&2
  exit 4
fi

# --- Extract, classify, aggregate --------------------------------------------
SPECS=()
for v in $SELECTED; do
  f="$(voice_file "$v")"
  # An extraction failure is not fatal here; the classification records it.
  python3 -I "$SCRIPT_DIR/review_json.py" extract "$f" \
    > "$REVIEW_DIR/review_${v}_${RID}.extracted.json" 2>/dev/null \
    || rm -f -- "$REVIEW_DIR/review_${v}_${RID}.extracted.json"
  SPECS+=("$v=$f")
done
write_verdicts
python3 -I "$SCRIPT_DIR/review_json.py" aggregate --root "$PROJECT_ROOT" "${SPECS[@]}" \
  > "$REVIEW_DIR/aggregate.md" || die "aggregate failed"

cat "$REVIEW_DIR/verdicts.txt"
printf 'AGGREGATE=%s\n' "$REVIEW_DIR/aggregate.md"

BAD="$(grep -cvE ' (VALID|CLEAN)$' "$REVIEW_DIR/verdicts.txt")"
[ "${BAD:-0}" -eq 0 ] && exit 0
exit 1
