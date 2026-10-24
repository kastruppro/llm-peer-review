#!/usr/bin/env bash
# llm-peer-review model resolver - the SINGLE SOURCE OF TRUTH accessor.
#
# Emits the canonical model strings from models.json so SKILL.md launch commands
# never hardcode a literal that can go stale (the exact failure that lost the
# Claude voice on 2026-07-09: a stale model string from a compaction summary was
# used instead of the canonical one in models.json). Read models.json, or call this.
#
# Fails LOUDLY (exit 64/65) on a missing file or unknown key - a review must
# never silently run on a guessed model.
#
# Usage:
#   models.sh <claude|gemini|codex> [model|effort|family|env|cli]   # default field: model
#   models.sh json                                                  # dump the whole file
#   models.sh check                                                 # print all three canonical strings
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_JSON="$SKILL_DIR/models.json"

usage() {
  echo "usage: models.sh <claude|gemini|codex> [model|effort|family|env|cli] | json | check" >&2
  exit 64
}

[ $# -ge 1 ] || usage
[ -f "$MODELS_JSON" ] || { echo "models.sh: models.json not found at $MODELS_JSON" >&2; exit 64; }

case "$1" in
  json)
    exec cat "$MODELS_JSON"
    ;;
  check)
    for v in claude gemini codex; do
      printf '%-7s %s\n' "$v" "$("$0" "$v" model)"
    done
    ;;
  claude|gemini|codex)
    voice="$1"; field="${2:-model}"
    val="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
voice, field = sys.argv[2], sys.argv[3]
v = d.get(voice)
if v is None:
    sys.exit(65)
if field not in v:
    sys.exit(66)
print(v[field])' "$MODELS_JSON" "$voice" "$field" 2>/dev/null)" || {
      echo "models.sh: no field '$field' for voice '$voice' in models.json" >&2
      exit 65
    }
    printf '%s\n' "$val"
    ;;
  *)
    usage
    ;;
esac
