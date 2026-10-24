#!/bin/bash
# Regression tests for models.sh: isolated python (no cwd imports) and a loud `check`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS="$SCRIPT_DIR/models.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review-models.XXXXXX")" && pwd -P)"
trap 'rm -rf -- "$T"' EXIT

FAILS=0
ok() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

# 1. A planted json.py in the cwd (the reviewed project) must never be imported.
mkdir -p "$T/proj"
printf 'import os\nopen(os.path.join(os.path.dirname(os.path.abspath(__file__)), "PWNED"), "w").close()\nfrom json import *\n' \
  > "$T/proj/json.py"
OUT="$(cd "$T/proj" && bash "$MODELS" claude model 2>/dev/null)"
RC=$?
[ ! -e "$T/proj/PWNED" ] && ok "models.sh does not import json.py from the cwd" \
  || fail "models.sh imported json.py from the cwd"
[ "$RC" -eq 0 ] && [ -n "$OUT" ] && ok "models.sh claude model still resolves" || fail "models.sh claude model rc=$RC"
rm -f "$T/proj/PWNED"
(cd "$T/proj" && bash "$MODELS" check >/dev/null 2>&1)
[ ! -e "$T/proj/PWNED" ] && ok "models.sh check does not import json.py from the cwd" \
  || fail "models.sh check imported json.py from the cwd"

# 2. `check` succeeds on the real registry ...
bash "$MODELS" check >/dev/null 2>&1 && ok "check exits 0 on the real models.json" || fail "check on real models.json"

# 3. ... and fails when any voice lookup fails.
mkdir -p "$T/copy"
cp "$MODELS" "$T/copy/models.sh"
python3 -I - "$SCRIPT_DIR/models.json" "$T/copy/models.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["codex"]["model"]
json.dump(d, open(sys.argv[2], "w"))
PY
bash "$T/copy/models.sh" check > "$T/check.out" 2> "$T/check.err"
RC=$?
[ "$RC" -ne 0 ] && ok "check exits non-zero when a voice has no model (rc=$RC)" || fail "check exited 0 with a missing codex model"
grep -Fq "codex" "$T/check.err" && ok "check names the failing voice on stderr" || fail "check stderr lacks the failing voice"

if [ "$FAILS" -ne 0 ]; then printf '%s check(s) failed\n' "$FAILS" >&2; exit 1; fi
echo 'ok - models.sh'
