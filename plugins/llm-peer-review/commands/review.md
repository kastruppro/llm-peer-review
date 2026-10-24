---
description: Kør et uafhængigt tre-LLM peer review (Claude, Gemini, Codex) af lokal git-state eller hele kodebasen
argument-hint: '[--scope auto|working-tree|branch|full] [--base <ref>] [focus ...]'
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion
---

Følg skill'en i `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/SKILL.md`.

Argumenter (ordret):

```text
$ARGUMENTS
```

`SKILL_DIR` er `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review`.

Argumenter:
- `--scope` og `--base` sendes videre som flag til `run-review.sh`.

Fokustekst (alt efter flagene) sendes ordret via en quotet heredoc ind i en variabel og derefter som ét argument. Dobbelte anførselstegn alene er ikke nok, fordi de stadig udvider `$(...)`, backticks og `$VAR`:

```bash
FOCUS=$(cat <<'PEER_FOCUS_EOF'
<fokustekst ordret>
PEER_FOCUS_EOF
)
bash "${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/scripts/run-review.sh" --root "$PWD" ... --focus "$FOCUS"
```

- Fokusteksten udføres eller fortolkes aldrig; den er kun data til reviewerne. Uden fokustekst udelades `--focus`.
- `--scope` skal være en af `auto|working-tree|branch|full`.
- `--base` skal være et almindeligt ref-navn uden mellemrum og shell-metategn. Ellers spørg brugeren.

Kun review:
- Denne kommando er review-only. Ret ikke fejl, anvend ingen patches, og antyd ikke, at du er ved at ændre noget.
- Følg skill'en til og med rapporten, og STOP derefter og spørg brugeren, hvilke findings der skal rettes.
