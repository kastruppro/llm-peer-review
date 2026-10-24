#!/bin/bash
# Regression tests for preflight.sh (agy discovery, auth detection, check summary).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/preflight.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-preflight.XXXXXX")"
FAILURES=0

cleanup() {
  rm -f -- "$TEST_DIR/home/.local/bin/agy" "$TEST_DIR"/*.out "$TEST_DIR"/*.err
  rmdir "$TEST_DIR/home/.local/bin" "$TEST_DIR/home/.local" "$TEST_DIR/home/.gemini/antigravity-cli" \
    "$TEST_DIR/home/.gemini" "$TEST_DIR/home" "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

HOME_DIR="$TEST_DIR/home"
mkdir -p "$HOME_DIR/.local/bin"

ok() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

run() { # run <name> <env-assignments...> -- <args>; sets RC, stdout in $TEST_DIR/NAME.out
  local name="$1"; shift
  if env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin PEERREVIEW_AGY_SYSTEM_PATHS=/nonexistent/agy "$@" >"$TEST_DIR/$name.out" 2>"$TEST_DIR/$name.err"; then
    RC=0
  else
    RC=$?
  fi
}

# 1. No agy anywhere: exit 127 plus the installer hint on stderr.
run noagy bash "$PREFLIGHT" agy-path
if [ "$RC" -eq 127 ] && grep -Fq 'curl -fsSL https://antigravity.google/cli/install.sh | bash' "$TEST_DIR/noagy.err"; then
  ok 'agy-path without agy exits 127 with installer hint'
else
  fail "agy-path without agy: rc=$RC"
fi

# 2. agy only in $HOME/.local/bin: print that path.
printf '#!/bin/bash\nexit 0\n' > "$HOME_DIR/.local/bin/agy"
chmod +x "$HOME_DIR/.local/bin/agy"
run fallback bash "$PREFLIGHT" agy-path
if [ "$RC" -eq 0 ] && [ "$(cat "$TEST_DIR/fallback.out")" = "$HOME_DIR/.local/bin/agy" ]; then
  ok 'agy-path falls back to $HOME/.local/bin/agy'
else
  fail "agy-path fallback: rc=$RC out=$(cat "$TEST_DIR/fallback.out")"
fi

# 3. agy on PATH wins and the printed path is absolute.
run onpath bash "$PREFLIGHT" agy-path
mkdir -p "$TEST_DIR/pathbin"
printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/pathbin/agy"
chmod +x "$TEST_DIR/pathbin/agy"
if env -i HOME="$HOME_DIR" PATH="$TEST_DIR/pathbin:/usr/bin:/bin" PEERREVIEW_AGY_SYSTEM_PATHS=/nonexistent/agy bash "$PREFLIGHT" agy-path >"$TEST_DIR/onpath.out" 2>/dev/null \
   && [ "$(cat "$TEST_DIR/onpath.out")" = "$TEST_DIR/pathbin/agy" ]; then
  ok 'agy-path prefers PATH'
else
  fail 'agy-path PATH preference'
fi
rm -f "$TEST_DIR/pathbin/agy"; rmdir "$TEST_DIR/pathbin"

# 4. No API key and no oauth dir: agy-auth MISSING, check exits 1.
run noauth bash "$PREFLIGHT" check
if [ "$RC" -eq 1 ] && grep -Eq '^agy-auth MISSING' "$TEST_DIR/noauth.out"; then
  ok 'check reports agy-auth MISSING and exits 1'
else
  fail "check without auth: rc=$RC"
fi

# 5. API key set: api-key; oauth dir: oauth.
run apikey ANTIGRAVITY_API_KEY=x bash "$PREFLIGHT" check
grep -Eq '^agy-auth ok api-key' "$TEST_DIR/apikey.out" && ok 'agy-auth api-key' || fail 'agy-auth api-key'
mkdir -p "$HOME_DIR/.gemini/antigravity-cli"
run oauth bash "$PREFLIGHT" check
grep -Eq '^agy-auth ok oauth' "$TEST_DIR/oauth.out" && ok 'agy-auth oauth' || fail 'agy-auth oauth'

# 6. One line per component.
MISSING_LINES=0
for comp in claude agy agy-auth codex jq python3 git models; do
  grep -Eq "^$comp (ok|MISSING)" "$TEST_DIR/oauth.out" || { fail "check lacks component line: $comp"; MISSING_LINES=1; }
done
[ "$MISSING_LINES" -eq 0 ] && ok 'check lists every component'

# 7. A planted json.py in the cwd (the reviewed project) is never imported.
mkdir -p "$TEST_DIR/proj"
printf 'import os\nopen(os.path.join(os.path.dirname(os.path.abspath(__file__)), "PWNED"), "w").close()\nfrom json import *\n' \
  > "$TEST_DIR/proj/json.py"
( cd "$TEST_DIR/proj" && run planted bash "$PREFLIGHT" check )
if [ ! -e "$TEST_DIR/proj/PWNED" ]; then ok 'check does not import json.py from the cwd'; else fail 'check imported json.py from the cwd'; fi
rm -f "$TEST_DIR/proj/json.py" "$TEST_DIR/proj/PWNED"; rmdir "$TEST_DIR/proj"

run bad bash "$PREFLIGHT" bogus
[ "$RC" -eq 64 ] && ok 'unknown subcommand exits 64' || fail "unknown subcommand rc=$RC"

[ "$FAILURES" -eq 0 ] || { printf '%s failure(s)\n' "$FAILURES" >&2; exit 1; }
