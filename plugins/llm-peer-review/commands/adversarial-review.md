---
description: Kør et tre-LLM peer review, der udfordrer valgt implementering, design og antagelser
argument-hint: '[--scope auto|working-tree|branch|full] [--base <ref>] [focus ...]'
disable-model-invocation: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

Følg skill'en i `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/SKILL.md` med disse argumenter og med `--adversarial`:
`$ARGUMENTS`

`SKILL_DIR` er `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review`.

Framing: dette er et udfordrende review, der udfordrer valgt implementering, design og antagelser. Det er ikke blot en strengere gennemgang af implementeringsfejl. Fokus er, om den valgte tilgang er den rigtige, hvilke antagelser den hviler på, og hvor designet kan svigte under virkelige forhold. Svæk ikke framingen og omskriv ikke brugerens fokus.

Argumenter:
- Tilføj altid `--adversarial`. `--scope` og `--base` sendes videre som flag til `run-review.sh`.
- Fokustekst efter flagene sendes som ét `--focus`-argument, quotet, og må aldrig splices ind i kommandoen som ukvoteret shell-tekst.
- Uden fokustekst udelades `--focus`.

Kun review:
- Denne kommando er review-only. Ret ikke fejl, anvend ingen patches, og antyd ikke, at du er ved at ændre noget.
- Følg skill'en til og med rapporten, og STOP derefter og spørg brugeren, hvilke findings der skal rettes.
