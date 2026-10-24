#!/usr/bin/env bash
# PreToolUse(Bash) guard for the llm-peer-review Claude voice.
#
# Blocks a review launch whose --model string doesn't match the canonical
# models.json. This is the enforcement backstop behind models.json + models.sh:
# even if a future launch hardcodes a literal (from memory or a compaction
# summary) instead of the resolver, a mismatch is stopped here.
#
# Scope is deliberately NARROW and FAIL-OPEN: it only acts on a command that
# carries the skill's hardening prefix (CLAUDE_CODE_DISABLE_CLAUDE_MDS) AND a
# `claude -p` headless call AND an explicit Claude `--model`. Anything else -
# any unrelated Bash command, any internal error, an unreadable models.json -
# passes through untouched. A guard must never wedge the user's shell.
#
# The other two voices are already guarded elsewhere: Gemini by
# gemini-review.sh (validates its model live against `agy models`), and Codex
# by explicit model + effort values resolved from this skill's models.json.
#
# Block protocol: exit 2 + stderr (PreToolUse convention - stderr is fed back
# to the model so it can self-correct).
set -uo pipefail

# Resolve beside this script so the guard follows the skill wherever it is
# installed or symlinked; the registry lives in the same scripts/ directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_JSON="$SCRIPT_DIR/models.json"

# --- read the hook payload (JSON on stdin), extract the bash command ----------
payload="$(cat 2>/dev/null || true)"
cmd="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass' 2>/dev/null || true)"

# --- scope gate: only a hardened Claude review launch ------------------------
# Ordered glob: the hardening prefix, then `claude -p`, then `--model`.
case "$cmd" in
  *CLAUDE_CODE_DISABLE_CLAUDE_MDS*claude*-p*--model*) : ;;
  *) exit 0 ;;
esac

# --- extract the --model value (quoted or bareword) --------------------------
model="$(printf '%s' "$cmd" | python3 -c '
import re, sys
s = sys.stdin.read()
m = re.search(r"--model\s+(\"[^\"]*\"|'"'"'[^'"'"']*'"'"'|\S+)", s)
if m:
    print(m.group(1).strip("\"'"'"'"))' 2>/dev/null || true)"

# Only enforce on a Claude model string; leave any other --model alone.
case "$model" in
  claude-*) : ;;
  *) exit 0 ;;
esac

# --- canonical value; fail OPEN if models.json can't be read -----------------
canon="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1]))["claude"]["model"])
except Exception:
    sys.exit(3)' "$MODELS_JSON" 2>/dev/null)" || exit 0
[ -n "$canon" ] || exit 0

# --- verdict -----------------------------------------------------------------
if [ "$model" != "$canon" ]; then
  cat >&2 <<EOF
llm-peer-review model guard: BLOCKED.
The Claude reviewer was launched with --model "$model", but the canonical
models.json says the Claude voice is "$canon".

models.json ($MODELS_JSON) is the SINGLE SOURCE OF TRUTH - a compaction summary
or a remembered string is NOT. Either:
  - use the canonical string: --model "\$("$SCRIPT_DIR/models.sh" claude)", or
  - if the model was deliberately changed, update models.json first.
EOF
  exit 2
fi
exit 0
