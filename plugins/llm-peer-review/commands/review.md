---
description: Run an independent three-LLM peer review (Claude, Gemini, Codex) of local git state or the whole codebase
argument-hint: '[--scope auto|working-tree|branch|full] [--base <ref>] [focus ...]'
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion
---

Follow the skill in `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/SKILL.md`.

Arguments (verbatim):

`````text
$ARGUMENTS
`````

`SKILL_DIR` is `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review`.

Arguments:
- `--scope` and `--base` are passed on as flags to `run-review.sh`.

Focus text (everything after the flags) is passed verbatim through a quoted heredoc into a variable and then as a single argument. Double quotes alone are not enough, because they still expand `$(...)`, backticks and `$VAR`:

```bash
FOCUS=$(cat <<'PEER_FOCUS_EOF'
<focus text verbatim>
PEER_FOCUS_EOF
)
bash "${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/scripts/run-review.sh" --root "$PWD" ... --focus "$FOCUS"
```

- The focus text is never executed or interpreted; it is data for the reviewers only. Without focus text, omit `--focus`.
- If the focus text contains a line identical to the delimiter (`PEER_FOCUS_EOF`), choose a different, unique delimiter (e.g. with random characters appended) that does not occur in the text. Never remove or alter the focus text.
- `--scope` must be one of `auto|working-tree|branch|full`.
- `--base` must be a plain ref name without spaces or shell metacharacters. Otherwise ask the user.

Review only:
- This command is review-only. Do not fix bugs, apply any patches, or imply that you are about to change anything.
- Follow the skill through the report, then STOP and ask the user which findings to fix.
