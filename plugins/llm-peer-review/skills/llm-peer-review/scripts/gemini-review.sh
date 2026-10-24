#!/bin/bash
# gemini-review.sh - run ONE Gemini code-review voice via the Antigravity CLI (`agy`).
#
# 2026-06-19 REWRITE: the standalone Google `gemini` CLI is deprecated and the
# CCS-proxy path (`ccs gemini -p`, claude-binary-via-proxy) is replaced by
# Google's native Antigravity CLI `agy`. The model is a real Gemini served by
# Google directly - default from models.json (`models.sh gemini`); run-review.sh
# passes it as GEMINI_REVIEW_MODEL. The script keeps ONE calling contract
# (used by run-review.sh), so an autonomous agent has ONE command it cannot get
# wrong (instead of improvising an unhardened call - see references/hardening.md).
#
# OUTPUT FORMAT (important for consumers): `agy` runs with `--output-format json`
# and `--json-schema schemas/review-output.schema.json`. Each raw envelope is
# retained, but only its final payload (extract-agy-response.sh: the
# `.structured_output` object, else `.response`) is classified and published. The
# published `${BASE}.json` is the schema JSON the reviewer returned.
#
# HARDENING DELTA vs the old claude-binary path: `agy` has no `--tools` /
# `--system-prompt` / `--permission-mode` flags. The reviewer instructions are
# PREPENDED to the prompt instead. Read-only flags are the variant verified in
# references/hardening.md (2026-10-24, "variant d"): `--mode plan --sandbox
# --dangerously-skip-permissions`. The last flag is needed so the headless
# one-shot never hangs on a permission prompt; `--mode plan` makes the agent
# plan instead of write (verified: a write probe produced no file), and
# `--sandbox` confines the terminal. `--disable-slash-commands` must NOT be
# passed: it silently disables plan mode. Plan mode is a workflow gate, NOT a
# tool-layer block (agy's own write_file still works when it chooses to), so the
# content manifest before/after remains mandatory. agy writes relative paths into
# the LAST --add-dir, so the project (CWD) is passed last and the run directory
# is never passed; only $REVIEW_DIR/shared (target.diff, prompt.md) is added
# before it. `agy` reads
# GEMINI.md / AGENTS.md (NOT CLAUDE.md) for workspace rules, so the CLAUDE.md
# orchestrator-contamination vector is gone but an AGENTS.md/GEMINI.md in the
# repo is a new one - the prepended system prompt + MISFIRE classification guard
# against it.
#
# Usage:
#   gemini-review.sh <RID> <prompt> [review-cwd]
#
# Env overrides (same as before, plus GEMINI_REVIEW_MODEL):
#   REVIEW_DIR              required private run directory created by the caller
#   GEMINI_REVIEW_OUT_BASE  optional output base override inside REVIEW_DIR
#   GEMINI_REVIEW_ACCEPT    'valid' (default; accepts VALID or attested CLEAN) or
#                           'response' (also accepts WEAK - analysis docs)
#   GEMINI_REVIEW_MODEL     exact agy model ID (default: `models.sh gemini`,
#                           i.e. gemini.model in models.json; run-review.sh
#                           always sets it from there)
#   GEMINI_ATTEMPT_CAP      seconds per attempt (default 900)
#   AGY_BIN                 agy executable (default `agy` from PATH; set it from
#                           `preflight.sh agy-path`)
#
# Writes (matching what wait-for-reviewers.sh expects):
#   ${BASE}.json                    published final payload: the review JSON
#                                   (or the error body of the last attempt)
#   ${BASE}.err                     combined attempt diagnostics
#   ${BASE}.attemptN.raw.json       complete immutable agy JSON envelope
#   ${BASE}.attemptN.final.md       extracted payload only (`.structured_output`,
#                                   else `.response`); the .md suffix is historical
#   ${BASE}.attemptN.err            agy/extraction stderr
#   ${BASE}.attemptN.classify.txt   verdict, exit code, and classifier counters
#   ${BASE}.VOICE                   which voice won (GEMINI:agy)
#   ${BASE}.SKIPPED                 present ONLY if both attempts failed
#
# Exit: 0 after any completed run (callers read the markers / classify the
# output - fail LOUDLY via .SKIPPED, never silently). Exit 64 ONLY for caller
# wiring errors (bad RID/prompt/cwd/cap/model) so they can't poison a review run.
set -u

RID="${1:?usage: gemini-review.sh <RID> <prompt> [cwd]}"
PROMPT="${2:?usage: gemini-review.sh <RID> <prompt> [cwd]}"
CWD="${3:-$PWD}"
REVIEW_ROOT="${REVIEW_DIR:?gemini-review requires a private REVIEW_DIR}"
[ -d "$REVIEW_ROOT" ] || { echo "[gemini-review] REVIEW_DIR does not exist: $REVIEW_ROOT" >&2; exit 64; }
BASE="${GEMINI_REVIEW_OUT_BASE:-${REVIEW_ROOT}/review_gemini_${RID}}"
case "$BASE" in
  "$REVIEW_ROOT"/*) ;;
  *) echo "[gemini-review] output base must stay inside REVIEW_DIR: $BASE" >&2; exit 64 ;;
esac

# --- Caller-wiring validation ----------------------------------------------
# RID is interpolated into rm/mv/redirect paths: restrict to safe chars so a
# crafted RID can never traverse outside /tmp (e.g. "x/../../.ssh/...").
case "$RID" in
  *[!A-Za-z0-9._-]*) echo "[gemini-review] bad RID (allowed: A-Za-z0-9._-): $RID" >&2; exit 64 ;;
esac
# A prompt starting with "-" would be parsed as a CLI flag by agy and could
# override the hardening flags (option injection).
case "$PROMPT" in
  -*) echo "[gemini-review] prompt must not start with '-' (option injection)" >&2; exit 64 ;;
esac
[ -d "$CWD" ] || { echo "[gemini-review] review-cwd does not exist: $CWD" >&2; exit 64; }

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_RESOLVER="$SKILL_DIR/models.sh"
[ -x "$MODEL_RESOLVER" ] || { echo "[gemini-review] models.sh missing beside this script" >&2; exit 64; }
MODEL="${GEMINI_REVIEW_MODEL:-$("$MODEL_RESOLVER" gemini)}"
# Same option-injection guard for the model name (it is passed as a CLI value).
case "$MODEL" in
  -*) echo "[gemini-review] GEMINI_REVIEW_MODEL must not start with '-' (option injection): $MODEL" >&2; exit 64 ;;
esac
# FAMILY-DIVERSITY GUARD: this is the GEMINI (Google-family) voice. `agy` also
# exposes Anthropic and OpenAI-family models, but routing this voice
# through Claude would collapse llm-peer-review's Anthropic/Google/OpenAI diversity
# into two Claude voices (the skill's "aldrig en 2. Claude" rule). Only accept a
# lowercase `gemini-...` CLI model ID here.
case "$MODEL" in
  gemini-*) ;;
  *) echo "[gemini-review] GEMINI_REVIEW_MODEL must be an exact lowercase Gemini CLI model ID (got: '$MODEL'). This is the Google-family voice - never route it through Claude/GPT via agy; it breaks family diversity. Set gemini.model in models.json (see 'models.sh gemini')." >&2; exit 64 ;;
esac

AGY="${AGY_BIN:-agy}"
command -v "$AGY" >/dev/null 2>&1 || { echo "[gemini-review] 'agy' (Antigravity CLI) not found (AGY_BIN='${AGY_BIN:-}', PATH) - install it or set AGY_BIN" >&2; exit 64; }
SCHEMA="$SKILL_DIR/../schemas/review-output.schema.json"
[ -f "$SCHEMA" ] || { echo "[gemini-review] review schema missing: $SCHEMA" >&2; exit 64; }

# `agy models` has emitted several line formats across versions: a bare ID,
# ID<TAB>label, and ID\tlabel where the separator is the two literal characters
# backslash+t. Extract the leading technical Gemini ID before exact matching so
# presentation labels never become part of model identity.
extract_agy_model_ids() {
  LC_ALL=C sed -nE 's/^(gemini-[[:alnum:]_.-]+).*/\1/p'
}

# Reject an unknown model name LOUDLY: `agy -p` silently falls back to a default
# model when given a bad --model, so a typo'd GEMINI_REVIEW_MODEL would run on
# the WRONG model and look successful (verified 2026-06-19). Only enforce when
# `agy models` actually returns a list - if it's empty (offline/auth hiccup),
# skip the check and let the run fail into .SKIPPED rather than block a valid
# model on a transient listing failure.
#
# NEVER hang on this: `agy models` can deadlock under agy-daemon contention (seen
# live 2026-06-19: an orphaned agy from a prior killed run made `agy models` hang
# 4+ min). This validation runs BEFORE the watchdog loop, so an unbounded call
# would freeze the whole script. Cap it; on timeout, skip validation (best-effort)
# and rely on the run + classify → .SKIPPED.
_MODELS_TMP="$(mktemp -t agymodels.XXXXXX 2>/dev/null || echo /tmp/agymodels.$$)"
( "$AGY" models >"$_MODELS_TMP" 2>/dev/null ) & _mpid=$!
_mw=0
while kill -0 "$_mpid" 2>/dev/null; do
  sleep 1; _mw=$((_mw+1))
  if [ "$_mw" -ge 20 ]; then
    echo "[gemini-review] 'agy models' did not return in 20s - skipping model pre-validation (relying on the run)" >&2
    for c in $(pgrep -P "$_mpid" 2>/dev/null); do kill "$c" 2>/dev/null; done
    kill "$_mpid" 2>/dev/null
    break
  fi
done
wait "$_mpid" 2>/dev/null
_AGY_MODELS="$(cat "$_MODELS_TMP" 2>/dev/null)"
rm -f "$_MODELS_TMP"
_AGY_MODEL_IDS="$(printf '%s\n' "$_AGY_MODELS" | extract_agy_model_ids)"
if [ -n "$_AGY_MODELS" ] && ! printf '%s\n' "$_AGY_MODEL_IDS" | grep -Fxq -- "$MODEL"; then
  echo "[gemini-review] unknown model '$MODEL' - agy would silently fall back. Available:" >&2
  printf '%s\n' "$_AGY_MODELS" | sed 's/^/    /' >&2
  exit 64
fi

CLASSIFY="$SKILL_DIR/classify-review.sh"
EXTRACT="$SKILL_DIR/extract-agy-response.sh"
# Without the classifier both attempts would silently reject ("" != VALID) and
# burn two full review runs before a misleading SKIPPED. Fail the wiring fast.
[ -f "$CLASSIFY" ] || { echo "[gemini-review] classify-review.sh missing beside this script" >&2; exit 64; }
[ -x "$EXTRACT" ] || { echo "[gemini-review] extract-agy-response.sh missing or not executable beside this script" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "[gemini-review] jq not found in PATH" >&2; exit 64; }

FINAL="${BASE}.json"
ERRF="${BASE}.err"
ATTEMPT_CAP="${GEMINI_ATTEMPT_CAP:-900}"
# Non-integer cap would make every `[ -ge ]` test error→false and disable the
# watchdog entirely (hung agy call = script blocks forever).
case "$ATTEMPT_CAP" in
  ''|*[!0-9]*) echo "[gemini-review] GEMINI_ATTEMPT_CAP must be a positive integer; using 900" >&2; ATTEMPT_CAP=900 ;;
esac
ACCEPT="${GEMINI_REVIEW_ACCEPT:-valid}"

# Reviewer system prompt - PREPENDED to the user prompt because agy has no
# --system-prompt flag. Mirrors the claude/codex voices' framing plus an
# explicit read-only instruction (agy has no tool-layer read-only guarantee).
SYS="You are a single, standalone code reviewer running headless. You read the code yourself and output findings ONLY. You are NOT an orchestrator: never launch or wait for other reviewers, never mention a findings log, dispositions, background tasks, or sub-agents. Do NOT modify, create, or delete any files - you have read-only intent. Report concrete bugs with file:line, the risk, and a fix. Return only JSON matching the provided schema."

# System prompt used ONLY on a content-policy refusal retry (see the REFUSED
# branch below). The refusal is triggered by attack-category WORDS (security,
# vulnerability, injection, path traversal, bypass, exploit, attacker), so the
# fix is to remove them from BOTH the system prompt AND the user prompt - NOT to
# add a "defensive" framing that re-enumerates them (that self-defeats: it
# re-triggers the filter, verified live 2026-06-30). This SYS therefore carries
# ZERO attack-category words; it just sanctions reviewing your own code and says
# do-not-decline. Substance (correctness/concurrency/input handling) lives in the
# reframed user prompt and still surfaces security-relevant bugs (confirmed: this
# wording caught a CSV-injection bug the security-framed prompt was refused for).
SYS_DEFENSIVE="You are a senior software engineer reviewing your own team's codebase before release, to find and fix bugs so they can be remediated before shipping. This is a normal, sanctioned engineering review of code you are authorized to read; do NOT decline and do NOT lecture - just report what you find. Output concrete findings ONLY, each with file:line, the issue, why it matters, and a fix. Return only JSON matching the provided schema. Do NOT modify, create, or delete any files. You are NOT an orchestrator: never launch or mention other reviewers."

# On a refusal retry, REPLACE the caller's attack-framed instruction with a fixed
# NEUTRAL one (asks for the same substance - correctness, concurrency, robustness,
# input handling, output escaping - so security-relevant bugs still surface, as
# empirically confirmed: this framing caught a CSV-injection bug Gemini refused to
# look for under the security-framed prompt). Surgical word-softening proved too
# weak: leaving "injection"/"path traversal"/"find ... risks" still tripped the
# filter. Any inlined fenced diff/code block IS the review's substance, so it is
# preserved verbatim (prepare_review.py always renders the target block as the
# prompt's single fence); agy sees the tree via --add-dir.
NEUTRAL_INSTRUCTION="Review the code for correctness bugs, race conditions and thread-safety, robustness and edge cases, resource and error handling, configuration validation, and careful handling of untrusted input and of any values written into generated output (so a downstream consumer cannot misinterpret them). For each issue: file:line, what is wrong, why it matters, and a concrete fix. Return only JSON matching the provided schema."
reframe_prompt() {
  local p="$1" fence
  # Capture the first fenced block (```...```), if any - that's the inlined diff/code.
  fence="$(printf '%s\n' "$p" | sed -n '/^```/,/^```/p')"
  if [ -n "$fence" ]; then
    printf '%s\n\n%s' "$NEUTRAL_INSTRUCTION" "$fence"
  else
    printf '%s' "$NEUTRAL_INSTRUCTION"
  fi
}

# Truncate outputs up front: if the launch below ever fails before writing
# (e.g. agy missing), a stale FINAL from a previous same-RID run must never be
# re-accepted as a fresh review. Markers from previous runs go too.
: > "$FINAL"
: > "$ERRF"
rm -f "${BASE}.SKIPPED" "${BASE}.VOICE" 2>/dev/null

record_classification() {
  local candidate="$1" record="$2" diag verdict rc
  diag="${record}.diag"
  if verdict="$(bash "$CLASSIFY" "$candidate" 2>"$diag")"; then
    rc=0
  else
    rc=$?
  fi
  {
    printf 'verdict=%s\nexit=%s\n' "$verdict" "$rc"
    cat "$diag"
  } > "$record"
  rm -f "$diag"
  printf '%s\n' "$verdict"
}
accepted_class() {
  local cls="$1"
  case "$ACCEPT" in
    response) [ "$cls" = "VALID" ] || [ "$cls" = "CLEAN" ] || [ "$cls" = "WEAK" ] ;;
    *)        [ "$cls" = "VALID" ] || [ "$cls" = "CLEAN" ] ;;
  esac
}

append_attempt_diagnostics() {
  {
    printf '[%s artifacts]\nraw=%s\nfinal=%s\nstderr=%s\nclassification=%s\n' \
      "$LAST_LABEL" "$LAST_RAW" "$LAST_FINAL" "$LAST_ERR" "$LAST_RECORD"
    printf '[%s stderr]\n' "$LAST_LABEL"
    cat "$LAST_ERR"
    printf '[%s classification]\n' "$LAST_LABEL"
    cat "$LAST_RECORD"
  } >> "$ERRF"
}

publish_attempt() {
  cp "$LAST_FINAL" "$FINAL"
}

# Kill a PID and all its descendants (macOS has no setsid(1); killing only the
# subshell leaves the agy child running, writing to the output file WHILE we
# classify it, and burning quota). The whole tree is collected FIRST (an orphan
# is no longer reachable via pgrep -P once its parent died), sent TERM, and any
# member still alive after a short grace (e.g. one that ignores TERM) gets KILL.
collect_tree() { # print PID and all descendants (parents first)
  local c
  echo "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$c"; done
}
is_alive() { # alive and not a zombie
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$st" ] || return 1
  case "$st" in Z*) return 1 ;; esac
  return 0
}
kill_tree() {
  local all p i alive
  all="$(collect_tree "$1")"
  for p in $all; do kill -TERM "$p" 2>/dev/null; done
  i=0
  while [ "$i" -lt 6 ]; do
    alive=0
    for p in $all; do is_alive "$p" && alive=1; done
    [ "$alive" -eq 0 ] && return 0
    sleep 0.5; i=$((i + 1))
  done
  for p in $all; do is_alive "$p" && kill -KILL "$p" 2>/dev/null; done
  return 0
}

# Workspace dirs: shared inputs first, project LAST (agy writes relative paths into
# the last --add-dir, so the manifest-checked project must be it). $REVIEW_DIR
# itself is never passed - other voices' outputs stay out of agy's workspace.
ADD_DIRS=()
[ -d "$REVIEW_ROOT/shared" ] && ADD_DIRS+=(--add-dir "$REVIEW_ROOT/shared")
ADD_DIRS+=(--add-dir "$CWD")

# One hardened attempt through agy. A retry here covers transient client/network
# blips and Google-side capacity. agy's own --print-timeout is a secondary cap;
# the watchdog loop below is the hard backstop.
run_attempt() {
  local label="$1" sys="$2" prompt="$3"
  local raw="${BASE}.${label}.raw.json"
  local out="${BASE}.${label}.final.md"
  local err="${BASE}.${label}.err"
  local record="${BASE}.${label}.classify.txt"
  local pid waited agy_rc
  : > "$raw"
  : > "$out"
  : > "$err"
  ( cd "$CWD" && "$AGY" -p "${sys}

${prompt}" \
      --model "$MODEL" \
      --output-format json \
      --json-schema "$SCHEMA" \
      --mode plan \
      --sandbox \
      --dangerously-skip-permissions \
      "${ADD_DIRS[@]}" \
      --print-timeout "${ATTEMPT_CAP}s" \
      </dev/null > "$raw" 2> "$err" ) &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5; waited=$((waited+5))
    if [ "$waited" -ge "$ATTEMPT_CAP" ]; then
      echo "[gemini-review] attempt timed out after ${ATTEMPT_CAP}s - killing process tree" >> "$err"
      kill_tree "$pid"
      break
    fi
  done
  if wait "$pid" 2>/dev/null; then
    agy_rc=0
  else
    agy_rc=$?
  fi

  if [ "$agy_rc" -eq 0 ] && "$EXTRACT" "$raw" > "$out" 2>> "$err"; then
    :
  else
    [ "$agy_rc" -ne 0 ] && echo "[gemini-review] agy exited with status $agy_rc" >> "$err"
    {
      printf 'AGY did not produce an extractable final response. See %s and %s.\n' "$raw" "$err"
      printf '{"is_error":true}\n'
    } > "$out"
  fi

  LAST_LABEL="$label"
  LAST_RAW="$raw"
  LAST_FINAL="$out"
  LAST_ERR="$err"
  LAST_RECORD="$record"
  LAST_CLASS="$(record_classification "$out" "$record")"
  accepted_class "$LAST_CLASS"
}

if run_attempt attempt1 "$SYS" "$PROMPT"; then
  append_attempt_diagnostics
  publish_attempt
  echo "GEMINI:agy" > "${BASE}.VOICE"
  echo "[gemini-review] accepted ($LAST_CLASS) via agy ($MODEL)" >&2
  exit 0
fi
append_attempt_diagnostics

# Refusal-aware retry: a content-policy over-refusal is deterministic for a given
# prompt, so retrying with the SAME prompt just refuses again and burns the run.
# On REFUSED, swap to the defensive own-code framing + a neutral-reframed prompt;
# any other rejection (transient/network/weak) retries unchanged as before.
CLS1="$LAST_CLASS"
if [ "$CLS1" = "REFUSED" ]; then
  echo "[gemini-review] attempt 1 REFUSED (content-policy over-refusal) - retrying with defensive framing + neutral reframe" >&2
  RETRY_SYS="$SYS_DEFENSIVE"
  RETRY_PROMPT="$(reframe_prompt "$PROMPT")"
else
  echo "[gemini-review] attempt 1 rejected ($CLS1) - retrying once" >&2
  RETRY_SYS="$SYS"
  RETRY_PROMPT="$PROMPT"
fi
if run_attempt attempt2 "$RETRY_SYS" "$RETRY_PROMPT"; then
  append_attempt_diagnostics
  publish_attempt
  echo "GEMINI:agy" > "${BASE}.VOICE"
  echo "[gemini-review] accepted ($LAST_CLASS) on retry" >&2
  exit 0
fi
append_attempt_diagnostics

# Both attempts failed: publish the LAST extracted/error body, but retain every
# raw envelope, extracted response, stderr file, and classification record.
publish_attempt
CLS2="$LAST_CLASS"
{
  echo "Gemini voice SKIPPED $(date '+%Y-%m-%d %H:%M:%S'): both agy attempts rejected (attempt 1: $CLS1, attempt 2: $CLS2)."
  if [ "$CLS1" = "REFUSED" ] || [ "$CLS2" = "REFUSED" ]; then
    echo "Cause: content-policy refusal that survived even the defensive-framing + neutral-reframe retry. This is a Gemini over-refusal, NOT auth/capacity - relaunching with the same model is unlikely to help; aggregate as a 2-voice (Claude+Codex) review and note the missing Google voice, or change gemini.model in models.json (see its note for the alternative tier) and relaunch only this voice with run-review.sh --voices gemini."
  else
    echo "Check: 'agy models' (auth/sign-in), network reachability to Google, model name '$MODEL'. stderr: $ERRF"
  fi
} > "${BASE}.SKIPPED"
echo "[gemini-review] SKIPPED - no usable Gemini voice (see ${BASE}.SKIPPED)" >&2
exit 0
