---
description: Check whether the Claude, Gemini (agy) and Codex CLIs are ready for peer review, and offer to install anything missing
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/scripts/preflight.sh" check
```

`preflight.sh check` exits with 1 when anything is `MISSING`. This is expected and not a command failure.

Pass the output on to the user unchanged (one line per component, `ok` or `MISSING ...`).

If everything is `ok`, say briefly that peer review is ready. Otherwise, for each `MISSING` line, suggest the fix and install only after confirmation:

- Use `AskUserQuestion` once per missing component with two options: install (`(Recommended)` on the first) or `Skip`. Never install without the user's confirmation.
- `agy` (Gemini via Antigravity CLI), official installer:
  ```bash
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  ```
- `codex`:
  ```bash
  npm install -g @openai/codex
  ```
- Authentication: ask the user to run the CLI interactively once (`!agy` for Gemini, `!codex login` for Codex) so the login is saved. Do not run the login for the user.
- If another component is missing (e.g. `claude`, `python3`, `jq`), explain what is missing and how it is typically installed, but do not install it unprompted.

After an installation, run the preflight command again and show the new output. If the installation was skipped, show the original output and mention that reviews with the missing voices will fail until they are installed (`--voices` can select the voices that are ready).
