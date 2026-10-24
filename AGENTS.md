# llm-peer-review

Skill og Claude Code-plugin, der kører tre uafhængige, parallelle code reviews (Claude, Gemini, Codex) og aggregerer kun gyldige stemmer.

## Layout

- `plugins/llm-peer-review/skills/llm-peer-review/` (`SK`): skill'en
  - `SKILL.md`, `agents/openai.yaml` (Codex), `references/`, `scripts/`, `schemas/`
  - `scripts/models.json`: eneste sted med modelnavne

## Test

```bash
cd plugins/llm-peer-review/skills/llm-peer-review/scripts && for t in test-*.sh; do bash "$t" || exit 1; done && python3 test-resolve-codex.py
```

## Regler

- Modelnavne må kun stå i `scripts/models.json`.
- Originalen i `<original triplereview skill>` må aldrig ændres.
- Kun Python-stdlib; bash-scripts skal virke i `/bin/bash` 3.2.
- SKILL.md, references og commands på dansk; reviewer-prompts på engelsk.
