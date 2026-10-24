#!/bin/bash
# classify-review.sh - decide whether a reviewer output file is a USABLE review,
# an orchestrator-roleplay MISFIRE, a CAPACITY/auth failure, a CLI ERROR, or
# empty/weak. Used by wait-for-reviewers.sh (sourced) and by the aggregation
# step (executed) to drive detect→relaunch/fallback. See SKILL.md §3a/§5/§6.
#
# Usage:   classify-review.sh <output-file>      # prints one class word
# Source:  source classify-review.sh ; classify_review <file>   # function only
#
# Classes (exit code in parens):
#   VALID(0)    real findings - locations or an attested structured single finding
#   CLEAN(0)    explicit NO_FINDINGS plus a concrete CHECKED attestation
#   EMPTY(2)    < 40 bytes  (also MISSING(2))
#   CAPACITY(3) auth/quota/503 failure (Gemini fetchAdminControls/TerminalQuota)
#   MISFIRE(4)  Claude roleplayed the orchestrator / emitted a meta-summary
#   WEAK(5)     nonempty, no strong signal (inspect: clean diff OR soft misfire)
#   ERROR(6)    CLI/exec error (claude is_error / max-retries)
#   REFUSED(7)  content-policy over-refusal ("I cannot fulfill ... vulnerabilities")
#               - declines the task entirely; distinct from WEAK so the caller can
#                 retry with a NEUTRAL reframe instead of an identical prompt.
#
# Why it is built the way it is (every rule traces to a real misclassification):
#  * Counts MATCHES, not lines. `grep -c` counts lines, and `claude -p
#    --output-format json` prints the whole envelope on ONE line, so a real
#    review with a dozen findings scored "1". _c() uses `grep -o | wc -l`.
#  * VALID keys on LOCATION signals (file.ext:NN, "file":/"line": keys, "line
#    NN"), never on bug-topic nouns alone. Path-qualified filenames accept any
#    sane extension so new languages do not require classifier changes. Root-level
#    filenames use a broad source/config extension set to avoid counting host:port
#    strings as locations. Reviewers echo bug-topic nouns, so those are only
#    secondary evidence; concrete locations are not.
#  * HARD capacity tokens (TerminalQuotaError, fetchAdminControls, ...) and the
#    Claude error envelope are checked BEFORE VALID, because a crash body can
#    carry a JS stack trace whose frames look like file:line (real incident: a
#    Gemini quota crash scored loc=9 off `.../bundle/chunk-*.js:304211`). SOFT
#    tokens (bare 503/UNAVAILABLE/429) can appear in legitimate review prose, so
#    they only decide the class when there are no real findings.
set -u

_c() { local n; n=$(grep -oiE "$1" -- "$2" 2>/dev/null | wc -l | tr -d ' '); echo "${n:-0}"; }

_checked_count() {
  awk '
    function concrete(item) {
      return item ~ /[\/\\]/ ||
        item ~ /[A-Za-z0-9_-]+\.[A-Za-z0-9]/ ||
        item ~ /(^|[[:space:],])(Dockerfile|Containerfile|Makefile|Justfile|Procfile|Rakefile|Gemfile|Vagrantfile|Brewfile|VERSION|README)([[:space:],]|$)/
    }
    BEGIN { waiting = 0; found = 0 }
    {
      if ($0 ~ /^[[:space:]]*CHECKED:[[:space:]]*$/) {
        waiting = 1
        next
      }
      if ($0 ~ /CHECKED:[[:space:]]*[^[:space:]]/) {
        item = $0
        sub(/^.*CHECKED:[[:space:]]*/, "", item)
        if (concrete(item)) found++
        waiting = 0
        next
      }
      if (waiting) {
        if ($0 ~ /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]+[^[:space:]]/) {
          item = $0
          sub(/^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]+/, "", item)
          if (concrete(item)) found++
          waiting = 0
          next
        }
        if ($0 ~ /^[[:space:]]*$/) next
        waiting = 0
      }
    }
    END { print found + 0 }
  ' "$1"
}

classify_review() {
  local f="$1"
  [ -f "$f" ] || { echo "MISSING"; return 2; }
  local bytes; bytes=$(wc -c < "$f" 2>/dev/null | tr -d ' '); [ -z "$bytes" ] && bytes=0
  if [ "$bytes" -lt 40 ]; then echo "EMPTY"; return 2; fi

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
  # LOCATION signals - the reliable "real finding" evidence. A path-qualified
  # filename may use any short alphanumeric extension (for example .ps1, .html,
  # or a future project-specific format). Root-level filenames stay constrained
  # to source/config/document extensions so URLs such as api.example.com:443 do
  # not become findings. Also recognize common extensionless build files.
  local loc; loc=$(_c '((([A-Za-z0-9_@%+=,.-]+[/\\])+[A-Za-z0-9_@%+=,.-]+\.[A-Za-z][A-Za-z0-9]{0,15})|([A-Za-z0-9_@%+=,.-]+\.(swift|py|pyi|ts|tsx|js|jsx|mjs|cjs|go|rs|java|kt|kts|cc|cpp|cxx|c|h|hpp|m|mm|rb|php|cs|fs|fsx|vb|scala|sh|bash|zsh|fish|ps1|psm1|psd1|bat|cmd|vbs|html|htm|css|scss|sass|less|vue|svelte|astro|sql|graphql|gql|json|jsonc|yaml|yml|toml|ini|cfg|conf|xml|svg|md|rst|txt|mako|jinja|jinja2|j2|lua|r|pl|pm|ex|exs|erl|hrl|dart|groovy|gradle|properties|env|po|pot|nginx|inc|webmanifest))|(Dockerfile|Containerfile|Makefile|Justfile|Procfile|Rakefile|Gemfile|Vagrantfile|Brewfile|VERSION|README)):[0-9]+|"(file|line|severity|finding|title)" *:|\blines? [0-9]+' "$f")
  # bug-topic nouns - SECONDARY (promptable; tie-breaker only)
  local top; top=$(_c 'race condition|data race|command injection|path traversal|force[- ]?unwrap|\btry!|non-?atomic|use[- ]after[- ]free|sql injection|toctou|lock[- ]order|integer overflow|null deref' "$f")
  # successful claude envelope - the CLAUDE voice emits it (gemini now runs via
  # `agy` and emits PLAIN MARKDOWN with NO envelope, so $ok=0 for it; that is
  # fine - agy reviews reach VALID purely on $loc file:line signals at the rule
  # below). A REAL capacity/auth failure can never carry "is_error":false, so a
  # success envelope plus real location signals beats QUOTED capacity tokens.
  # Found live 2026-06-10: reviewing THIS skill's own scripts (whose content IS
  # the error patterns) made a valid codex review (loc=21) classify CAPACITY,
  # because its findings quoted RESOURCE_EXHAUSTED/ConnectionRefused.
  local ok; ok=$(_c '"type": ?"result".*"is_error": ?false' "$f")
  # content-policy REFUSAL (Gemini & co. sometimes decline a security-framed review:
  # "Sorry, I cannot fulfill your request to analyze the code for security
  # vulnerabilities ..."). It carries no file:line so it would otherwise score WEAK
  # and trigger an identical-prompt retry that refuses again. High-precision verbs only.
  local refuse; refuse=$(_c "i (can'?t|cannot|am unable to|am not able to|won'?t|will not) (fulfill|comply|assist|help|analyze|complete|provide|process|continue)|cannot fulfill (your|this) request|unable to (assist|help|fulfill|comply) with|i must decline|i'?m sorry,? but i (can|cannot|am)|against (my|the) (content|usage|safety) (polic|guideline)|as an ai (language )?model,? i" "$f")
  # A clean review is only trustworthy when it explicitly attests both the
  # zero-finding result and what it actually checked.
  local nofindings; nofindings=$(_c '(^|[^A-Z_])NO_FINDINGS([^A-Z_]|$)' "$f")
  # Accept either inline content or a following Markdown list. grep processes
  # one line at a time, so this small state machine is intentional.
  local checked; checked=$(_checked_count "$f")

  # Normalize only successful text envelopes for field/attestation detection.
  # Keep error and capacity detection on the original output.
  local structured=0 final_text
  final_text=$(cat "$f")
  if command -v jq >/dev/null 2>&1; then
    if jq -e 'type == "object" and (.is_error != true) and ((.result | type) == "string")' "$f" >/dev/null 2>&1; then
      final_text=$(jq -r '.result' "$f")
    elif jq -e 'type == "object" and .status == "SUCCESS" and ((.response | type) == "string")' "$f" >/dev/null 2>&1; then
      final_text=$(jq -r '.response' "$f")
    fi
  fi
  if [ "$loc" -ge 1 ] &&
     printf '%s\n' "$final_text" | grep -qiE '^Severity: *(P[0-3]|critical|high|medium|low)' &&
     printf '%s\n' "$final_text" | grep -qiE '^Location: *[^[:space:]]+:[0-9]+' &&
     printf '%s\n' "$final_text" | grep -qiE '^Behavior: *[^[:space:]]' &&
     printf '%s\n' "$final_text" | grep -qiE '^Impact: *[^[:space:]]' &&
     printf '%s\n' "$final_text" | grep -qiE '^Fix: *[^[:space:]]' &&
     [ "$(printf '%s\n' "$final_text" | _checked_count /dev/stdin)" -ge 1 ]; then
    structured=1
  fi

  echo "structured=$structured loc=$loc top=$top mis=$mis caphard=$caphard capsoft=$capsoft refuse=$refuse nofindings=$nofindings checked=$checked err=$err ok=$ok bytes=$bytes" >&2

  # failures that masquerade as content (must win over loc) -------------------
  if [ "$err" -ge 1 ];     then echo "ERROR";    return 6; fi
  # success-envelope + real findings: capacity tokens are quoted prose --------
  if [ "$ok" -ge 1 ] && { [ "$loc" -ge 2 ] || { [ "$loc" -ge 1 ] && [ "$top" -ge 2 ]; }; }; then echo "VALID"; return 0; fi
  if [ "$caphard" -ge 1 ]; then echo "CAPACITY"; return 3; fi
  if [ "$structured" -eq 1 ] && [ "$mis" -eq 0 ] && [ "$refuse" -eq 0 ]; then echo "VALID"; return 0; fi
  # Legacy multi-location output remains supported.
  if [ "$loc" -ge 2 ] || { [ "$loc" -ge 1 ] && [ "$top" -ge 2 ]; }; then echo "VALID"; return 0; fi
  # content-policy refusal: no findings + an explicit decline. Checked after VALID
  # (a real review that merely quotes such a phrase still wins on its locations) and
  # before WEAK so the caller can react with a neutral-reframe retry.
  if [ "$refuse" -ge 1 ]; then echo "REFUSED"; return 7; fi
  # weaker / generic failure signals, only when there were no real findings ----
  if [ "$capsoft" -ge 1 ]; then echo "CAPACITY"; return 3; fi
  if [ "$mis" -ge 1 ];     then echo "MISFIRE";  return 4; fi
  if [ "$nofindings" -ge 1 ] && [ "$checked" -ge 1 ]; then echo "CLEAN"; return 0; fi
  echo "WEAK"; return 5
}

# Run as a CLI only when executed directly (not when sourced by the watcher).
# The :- guards keep `set -u` from tripping if sourced from a shell that does
# not populate BASH_SOURCE (e.g. zsh).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  [ "${1:-}" = "" ] && { echo "usage: $0 <reviewer-output-file>" >&2; exit 64; }
  classify_review "$1"
fi
