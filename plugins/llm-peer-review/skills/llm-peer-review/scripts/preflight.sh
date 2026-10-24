#!/bin/bash
# preflight.sh - environment checks for llm-peer-review. No network, no model calls.
#
# Usage:
#   preflight.sh agy-path   print the absolute agy path (PATH first, then known install dirs);
#                           exit 127 with the installer hint on stderr when none is found
#   preflight.sh check      one line per component: "<name> ok|MISSING <detail>"; exit 1 if any MISSING
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_HINT='curl -fsSL https://antigravity.google/cli/install.sh | bash'

find_agy() {
  local p c
  p="$(command -v agy 2>/dev/null || true)"
  case "$p" in
    /*) [ -x "$p" ] && { printf '%s\n' "$p"; return 0; } ;;
  esac
  # PEERREVIEW_AGY_SYSTEM_PATHS (colon-separated) replaces the system dirs; tests use it
  # so a real install on the host cannot leak in.
  local sys="${PEERREVIEW_AGY_SYSTEM_PATHS-/opt/antigravity/bin/agy:/usr/local/bin/agy:/opt/homebrew/bin/agy}" IFS=:
  for c in "${HOME:-/nonexistent}/.local/bin/agy" $sys; do
    [ -f "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

line() { # line <name> <detail-if-ok> <detail-if-missing> <rc>
  if [ "$4" -eq 0 ]; then
    printf '%s ok %s\n' "$1" "$2"
  else
    printf '%s MISSING %s\n' "$1" "$3"
    FAILED=1
  fi
}

check_cmd() { # check_cmd <name> <hint>
  local p
  if p="$(command -v "$1" 2>/dev/null)"; then line "$1" "$p" "" 0; else line "$1" "" "$2" 1; fi
}

case "${1:-}" in
  agy-path)
    if ! find_agy; then
      echo "preflight: agy (Antigravity CLI) not found. Install it with: $INSTALL_HINT" >&2
      exit 127
    fi
    ;;
  check)
    FAILED=0
    check_cmd claude "install Claude Code"
    if AGY="$(find_agy)"; then line agy "$AGY" "" 0; else line agy "" "install with: $INSTALL_HINT" 1; fi
    if [ -n "${ANTIGRAVITY_API_KEY:-}" ]; then
      line agy-auth api-key "" 0
    elif [ -d "${HOME:-/nonexistent}/.gemini/antigravity-cli" ]; then
      line agy-auth oauth "" 0
    else
      line agy-auth "" "set ANTIGRAVITY_API_KEY or sign in once with agy (creates ~/.gemini/antigravity-cli)" 1
    fi
    if CODEX_PATH="$(python3 -I "$SCRIPT_DIR/resolve-codex.py" 2>/dev/null)" && [ -n "$CODEX_PATH" ]; then
      line codex "$CODEX_PATH" "" 0
    else
      line codex "" "no compatible Codex CLI (see resolve-codex.py; set PEERREVIEW_CODEX_BIN)" 1
    fi
    check_cmd jq "install jq"
    check_cmd python3 "install python3"
    check_cmd git "install git"
    if MODELS="$(bash "$SCRIPT_DIR/models.sh" check 2>&1)"; then
      line models "$(printf '%s' "$MODELS" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')" "" 0
    else
      line models "" "models.sh check failed" 1
    fi
    [ "$FAILED" -eq 0 ] || exit 1
    ;;
  *)
    echo "usage: preflight.sh agy-path | check" >&2
    exit 64
    ;;
esac
