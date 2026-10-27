# llm-peer-review

A skill and Claude Code plugin that runs three independent, parallel code reviews (Claude, Gemini, Codex) and aggregates only valid votes.

## Layout

- `plugins/llm-peer-review/skills/llm-peer-review/` (`SK`): the skill
  - `SKILL.md`, `agents/openai.yaml` (Codex), `references/`, `scripts/`, `schemas/`
  - `scripts/models.json`: the only place with model names

## Test

```bash
cd plugins/llm-peer-review/skills/llm-peer-review/scripts && for t in test-*.sh; do bash "$t" || exit 1; done && for p in test-*.py; do python3 "$p" || exit 1; done
```

## Rules

- Model names may only appear in `scripts/models.json`.
- Python stdlib only; bash scripts must work in `/bin/bash` 3.2.
- All documentation, commands and prompts are in English.
