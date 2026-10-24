#!/bin/bash
# classify-review.sh - decide whether a reviewer output file is a USABLE review,
# an orchestrator-roleplay MISFIRE, a CAPACITY/auth failure, a CLI ERROR, or
# empty/weak. Used by wait-for-reviewers.sh (sourced) and by the aggregation
# step (executed) to drive detect→relaunch/fallback. See SKILL.md §3a/§5/§6.
#
# Usage:   classify-review.sh <output-file>      # prints one class word
# Source:  source classify-review.sh ; classify_review <file>   # function only
#
# Validity is decided by the JSON schema (review_json.py classify); the regexes
# below are used ONLY to recognise error/refusal/misfire bodies that are not JSON.
#
# Classes (exit code in parens):
#   VALID(0)    schema-valid review with >=1 finding
#   CLEAN(0)    schema-valid approve review, 0 findings, non-empty `checked`
#   EMPTY(2)    < 40 bytes  (also MISSING(2))
#   CAPACITY(3) auth/quota/503 failure (Gemini fetchAdminControls/TerminalQuota)
#   MISFIRE(4)  Claude roleplayed the orchestrator / emitted a meta-summary
#   WEAK(5)     nonempty but not a usable review (schema violations, needs-attention
#               without findings, or unclassifiable prose)
#   ERROR(6)    CLI/exec error (claude is_error / agy non-SUCCESS / max-retries)
#   REFUSED(7)  content-policy over-refusal ("I cannot fulfill ... vulnerabilities")
#               - declines the task entirely; distinct from WEAK so the caller can
#                 retry with a NEUTRAL reframe instead of an identical prompt.
#
# Order: MISSING/EMPTY -> review_json.py (VALID/CLEAN/WEAK/ERROR are returned as
# is) -> only for NOTJSON bodies: err -> caphard -> refuse -> capsoft -> mis -> WEAK.
# Counts MATCHES, not lines (_c uses `grep -o | wc -l`), because an envelope may
# be printed on ONE line.
set -u

_c() { local n; n=$(grep -oiE "$1" -- "$2" 2>/dev/null | wc -l | tr -d ' '); echo "${n:-0}"; }

classify_review() {
  local f="$1"
  [ -f "$f" ] || { echo "MISSING"; return 2; }
  local bytes; bytes=$(wc -c < "$f" 2>/dev/null | tr -d ' '); [ -z "$bytes" ] && bytes=0
  if [ "$bytes" -lt 40 ]; then echo "EMPTY"; return 2; fi

  # Schema-based classification first. Only a body that is not JSON at all
  # (CLI crash text, refusal prose, orchestrator roleplay) reaches the regexes.
  local here py cls
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  py="$here/review_json.py"
  cls=$(python3 -I "$py" classify "$f" 2>/dev/null) || true
  case "$cls" in
    VALID|CLEAN) echo "$cls"; return 0 ;;
    WEAK)        echo "WEAK";  return 5 ;;
    ERROR)       echo "ERROR"; return 6 ;;
    NOTJSON)     ;;
    *)           echo "classify-review: review_json.py gave no class for $f" >&2
                 echo "WEAK"; return 5 ;;
  esac

  # capacity - HARD: error-body-specific, never appears in a normal code review.
  # 2026-06-10: added CCS-proxy failure modes (gemini/codex now run via
  # `ccs <provider> -p` against the remote proxy): ConnectionRefused / "Unable
  # to connect to API" / ECONNREFUSED. Deliberately NOT matching the bare
  # phrase "Authentication failed": CCS prints "[i] … auth readiness:
  # Authentication failed - check auth token in settings" on EVERY run
  # (including successful ones) - matching it would misclassify valid reviews
  # if stderr ever leaks into the classified file.
  local caphard; caphard=$(_c 'fetchAdminControls|GaxiosError|RESOURCE_EXHAUSTED|service is currently unavailable|loadCodeAssist|retrieveUserQuota|TerminalQuotaError|exhausted your (capacity|quota)|capacity on this model|error when talking to (the )?gemini|overloaded_error|insufficient_quota|ModelNotFoundError|Requested entity was not found|ValidationRequiredError|Verify your account to continue|ValidationRequired|Unable to connect to API|ConnectionRefused|ECONNREFUSED|Failed to connect to remote proxy|token invalidated|not logged in|please .*sign in|^[[:space:]]*(error:[[:space:]]*|401[[:space:]]+)?unauthorized([.!:]|[[:space:]]*$)|"(error|message)"[[:space:]]*:[[:space:]]*"unauthorized([.!:]|")|authentication required' "$f")
  # capacity - SOFT: generic; could occur in real review prose, so weighed last
  local capsoft; capsoft=$(_c 'UNAVAILABLE|"code": ?(429|500|503)|quota.{0,15}(exceed|exhaust)|429 Too Many|status ?: ?503' "$f")
  # CLI / execution error (Claude headless envelope - not review prose)
  local err; err=$(_c '"is_error": ?true|error_max_structured_output_retries|error_during_execution|"subtype": ?"error' "$f")
  # orchestrator-roleplay / non-synthesis META (high precision)
  local mis; mis=$(_c 'reviewers are launched|launch(ed|ing) the (three )?reviewers|tracked background task|findings\.log|fabricated disposition|no (fabricated )?disposition|consolidated report from [0-9]+|parallel review agents|i have not (written|created|recorded|run|yet)|as the orchestrator|waiting for (the )?(other )?reviewers (to|before)|i will (now )?(launch|dispatch|wait for|aggregate)|once the reviewers (complete|return)|sub-?agents? (have|to|are|will)' "$f")
  # content-policy REFUSAL (Gemini & co. sometimes decline a security-framed review:
  # "Sorry, I cannot fulfill your request to analyze the code for security
  # vulnerabilities ..."). It carries no file:line so it would otherwise score WEAK
  # and trigger an identical-prompt retry that refuses again. High-precision verbs only.
  local refuse; refuse=$(_c "i (can'?t|cannot|am unable to|am not able to|won'?t|will not) (fulfill|comply|assist|help|analyze|complete|provide|process|continue)|cannot fulfill (your|this) request|unable to (assist|help|fulfill|comply) with|i must decline|i'?m sorry,? but i (can|cannot|am)|against (my|the) (content|usage|safety) (polic|guideline)|as an ai (language )?model,? i" "$f")
  echo "json=notjson mis=$mis caphard=$caphard capsoft=$capsoft refuse=$refuse err=$err bytes=$bytes" >&2

  if [ "$err" -ge 1 ];     then echo "ERROR";    return 6; fi
  if [ "$caphard" -ge 1 ]; then echo "CAPACITY"; return 3; fi
  # content-policy refusal: no review + an explicit decline. Checked before WEAK
  # so the caller can react with a neutral-reframe retry.
  if [ "$refuse" -ge 1 ]; then echo "REFUSED"; return 7; fi
  # weaker / generic failure signals (no schema-valid review exists here) -------
  if [ "$capsoft" -ge 1 ]; then echo "CAPACITY"; return 3; fi
  if [ "$mis" -ge 1 ];     then echo "MISFIRE";  return 4; fi
  echo "WEAK"; return 5
}

# Run as a CLI only when executed directly (not when sourced by the watcher).
# The :- guards keep `set -u` from tripping if sourced from a shell that does
# not populate BASH_SOURCE (e.g. zsh).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  [ "${1:-}" = "" ] && { echo "usage: $0 <reviewer-output-file>" >&2; exit 64; }
  classify_review "$1"
fi
