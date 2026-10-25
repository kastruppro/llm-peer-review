#!/bin/bash
# run-review.sh - the single entry point of llm-peer-review.
#
# Usage:
#   run-review.sh [--root DIR] [--scope auto|working-tree|branch|full] [--base REF]
#                 [--adversarial] [--focus TEXT] [--voices claude,gemini,codex]
#
# Flow: preflight (selected voices only) -> private run dir -> snapshot before ->
# prepare shared inputs (then read-only + checksummed) -> launch voices in
# parallel -> watch -> stop every voice tree -> snapshot after + shared/ check
# -> extract, classify, aggregate. The first stdout line is REVIEW_DIR=<path>.
# The run directory is never deleted by this script.
#
# Exit codes:
#   0  every selected voice is VALID/CLEAN
#   1  at least one selected voice is missing/invalid; aggregate.md is written
#   2  preflight, wiring, watcher failure or watcher timeout (no aggregate); the
#      voice process trees are stopped first
#   130/143  interrupted (INT/TERM); voices stopped, run dir kept
#   3  nothing to review (from prepare_review.py)
#   4  the project or shared/ (target.diff, prompt.md) changed while the
#      reviewers ran (diff on stderr; no aggregate), also checked after a
#      watcher failure/timeout
#
# Watcher timing knobs (env): REVIEW_POLL_INTERVAL, REVIEW_MAX_ITER, REVIEW_STALE_ITERS.
set -u

# Keep only absolute PATH entries: CLIs are looked up after `cd "$PROJECT_ROOT"`,
# so a relative entry ("", ".", "bin") would let the reviewed project supply claude/git/jq.
_abs_path=""; _old_ifs="$IFS"; IFS=:; set -f
for _d in $PATH; do case "$_d" in /*) _abs_path="${_abs_path:+$_abs_path:}$_d" ;; esac; done
set +f; IFS="$_old_ifs"; PATH="$_abs_path"; export PATH; unset _abs_path _old_ifs _d

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

# The baseline comes before anything else touches the project (prepare included).
python3 -I "$SCRIPT_DIR/snapshot.py" "$PROJECT_ROOT" > "$REVIEW_DIR/snapshot.before.json" \
  || die "snapshot before the review failed"

# --- Shared inputs -----------------------------------------------------------
# shared/ is readable by every voice (agy gets it as --add-dir and is not blocked
# at the tool layer). After prepare it is made read-only and checksummed; the
# owner can still chmod/replace it, so the checksum is the actual detection.
shared_manifest() { # deterministic listing of shared/ with sha256 per regular file
  ( cd "$REVIEW_DIR/shared" 2>/dev/null || { echo "shared/ missing"; exit 0; }
    find . -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then printf 'link %s -> %s\n' "$f" "$(readlink "$f")"
      elif [ -f "$f" ]; then printf '%s %s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$f"
      else printf 'other %s\n' "$f"
      fi
    done )
}
shared_changed() { # print the diff on stderr; 0 = changed
  shared_manifest > "$REVIEW_DIR/shared.sha256.after"
  diff -u "$REVIEW_DIR/shared.sha256" "$REVIEW_DIR/shared.sha256.after" >&2 && return 1
  echo "run-review: shared/ (the voices' common inputs) was modified during the review" >&2
  return 0
}
# Give write access back on every exit, so the run dir can be cleaned up (SKILL.md §7).
trap 'chmod -R u+w "$REVIEW_DIR/shared" 2>/dev/null' EXIT

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
chmod -R a-w "$REVIEW_DIR/shared" || die "cannot make shared/ read-only"
shared_manifest > "$REVIEW_DIR/shared.sha256" || die "cannot checksum shared/"

# --- Process control ---------------------------------------------------------
CLAUDE_PID=0; CODEX_PID=0; GEMINI_PID=0; WATCH_PID=0

is_alive() { # alive and not a zombie (kill -0 succeeds on unreaped zombies)
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$st" ] || return 1   # no such process
  case "$st" in Z*) return 1 ;; esac
  return 0
}

collect_tree() { # print PID and all descendants (parents first)
  local c
  echo "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$c"; done
}

group_alive() { # any non-zombie process left in process group $1?
  ps -axo pgid=,stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }'
}

# Stop every voice process tree. Each voice is a background job started under
# `set -m`, so it leads its own process group and descendants that were orphaned
# (the watcher itself kills only the wrapper PID on timeout) stay reachable via
# the group. A recursive PID walk covers anything that left the group. TERM,
# short grace period, KILL survivors, reap our own children. A process group
# cannot be reused by an unrelated process while it has members, and individual
# PIDs are only signalled while still alive.
stop_voices() {
  local p q all="" i alive
  for p in $CLAUDE_PID $CODEX_PID $GEMINI_PID; do
    [ "$p" != "0" ] && is_alive "$p" && all="$all $(collect_tree "$p")"
  done
  for p in $CLAUDE_PID $CODEX_PID $GEMINI_PID; do
    [ "$p" != "0" ] && group_alive "$p" && kill -TERM -- "-$p" 2>/dev/null
  done
  for q in $all; do is_alive "$q" && kill -TERM "$q" 2>/dev/null; done
  i=0
  while [ "$i" -lt 10 ]; do
    alive=0
    for q in $all; do is_alive "$q" && alive=1; done
    for p in $CLAUDE_PID $CODEX_PID $GEMINI_PID; do
      [ "$p" != "0" ] && group_alive "$p" && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.5
    i=$((i + 1))
  done
  for p in $CLAUDE_PID $CODEX_PID $GEMINI_PID; do
    [ "$p" != "0" ] && group_alive "$p" && kill -KILL -- "-$p" 2>/dev/null
  done
  for q in $all; do is_alive "$q" && kill -KILL "$q" 2>/dev/null; done
  for p in $CLAUDE_PID $CODEX_PID $GEMINI_PID; do
    [ "$p" != "0" ] && { wait "$p"; } 2>/dev/null
  done
  return 0
}

on_signal() { # on_signal <exit-code>
  trap '' INT TERM
  [ "$WATCH_PID" != "0" ] && kill "$WATCH_PID" 2>/dev/null
  stop_voices
  echo "run-review: interrupted; voices stopped (run dir kept: $REVIEW_DIR)" >&2
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# --- Launch the selected voices in parallel ----------------------------------
set -m   # every background job leads its own process group (see stop_voices)
CLAUDE_SYSTEM="You are one standalone code reviewer, not an orchestrator. Read the code yourself. Never launch agents or other reviewers. Never modify files. Return only concrete review findings with file:line evidence."

if [ "$WANT_CLAUDE" -eq 1 ]; then
  (
    cd "$PROJECT_ROOT" || exit 2
    CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 exec claude -p \
      --model "$CLAUDE_MODEL" \
      --effort "$CLAUDE_EFFORT" \
      --setting-sources user \
      --strict-mcp-config \
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
"$SCRIPT_DIR/wait-for-reviewers.sh" "$RID" "$CLAUDE_PID" "$CODEX_PID" "$GEMINI_PID" &
WATCH_PID=$!
wait "$WATCH_PID"
WATCH_RC=$?
WATCH_PID=0
printf 'watcher exit=%s\n' "$WATCH_RC"
# Always stop every voice tree before any check: a finished wrapper can leave
# descendants (e.g. an attempt-1 agy child that ignored TERM) that would
# otherwise keep writing after snapshot.after.
stop_voices

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

snapshot_changed() { # snapshot after; print the diff on stderr; 0 = changed
  python3 -I "$SCRIPT_DIR/snapshot.py" "$PROJECT_ROOT" > "$REVIEW_DIR/snapshot.after.json" \
    || die "snapshot after the review failed"
  diff -u "$REVIEW_DIR/snapshot.before.json" "$REVIEW_DIR/snapshot.after.json" >&2 && return 1
  return 0
}

inputs_changed() { # project snapshot AND shared/ checksum (both always run); 0 = changed
  local changed=1
  snapshot_changed && changed=0
  shared_changed && changed=0
  return "$changed"
}

case "$WATCH_RC" in
  0|1) ;;
  *)
    # Wiring error or timeout (voices already stopped above): check the inputs.
    write_verdicts
    if inputs_changed; then
      echo "run-review: the project or shared/ changed while the reviewers ran (see the diff above); watcher exit $WATCH_RC; no aggregate written." >&2
      exit 4
    fi
    echo "run-review: watcher failed (exit $WATCH_RC); no aggregate written" >&2
    exit 2
    ;;
esac

# --- Read-only invariant -----------------------------------------------------
if inputs_changed; then
  echo "run-review: the project or shared/ changed while the reviewers ran (see the diff above); no aggregate written. Re-run on a stable snapshot." >&2
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
