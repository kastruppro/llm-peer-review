---
description: Kør et uafhængigt tre-LLM peer review (Claude, Gemini, Codex) af lokal git-state eller hele kodebasen
argument-hint: '[--scope auto|working-tree|branch|full] [--base <ref>] [focus ...]'
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

Følg skill'en i `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/SKILL.md` med disse argumenter:
`$ARGUMENTS`

`SKILL_DIR` er `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review`.

Argumenter:
- `--scope` og `--base` sendes videre som flag til `run-review.sh`.
- Fokustekst efter flagene sendes som ét `--focus`-argument, quotet, og må aldrig splices ind i kommandoen som ukvoteret shell-tekst.
- Uden fokustekst udelades `--focus`. Tilføj ikke egne review-instruktioner.

Kun review:
- Denne kommando er review-only. Ret ikke fejl, anvend ingen patches, og antyd ikke, at du er ved at ændre noget.
- Følg skill'en til og med rapporten, og STOP derefter og spørg brugeren, hvilke findings der skal rettes.
