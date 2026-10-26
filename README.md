# llm-peer-review

Tre uafhængige LLM-reviews af samme kode, aggregeret til en evidensbaseret konsensus.

Reviewerne er Claude (Claude CLI), Gemini (Antigravity CLI `agy`) og Codex (native Codex CLI). De læser det samme stabile, read-only snapshot og returnerer JSON efter `schemas/review-output.schema.json`. Kun schema-gyldige svar tæller som stemme, og findings, som flere stemmer peger på, samles i klynger. Repoet pakker det både som en Claude Code-plugin og som en selvstændig skill, der også virker i Codex.

Efter rapporten stopper flowet og spørger, hvilke findings der skal rettes. Intet rettes automatisk.

## Installation (Claude Code)

```
/plugin marketplace add kastruppro/llm-peer-review
/plugin install llm-peer-review@kastruppro-peer-review
/reload-plugins
/llm-peer-review:setup
```

Fra en lokal klon kan du i stedet bruge stien: `/plugin marketplace add /sti/til/llm-peer-review`.

`/llm-peer-review:setup` kører preflight og tilbyder at installere manglende CLI'er (efter bekræftelse).

## Brug

| Command | Formål |
|---|---|
| `/llm-peer-review:review [--scope auto\|working-tree\|branch\|full] [--base <ref>] [focus ...]` | Almindeligt tre-LLM review |
| `/llm-peer-review:adversarial-review [samme argumenter]` | Udfordrer valgt implementering, design og antagelser |
| `/llm-peer-review:setup` | Tjek og installér Claude-, `agy`- og Codex-CLI |

- `--scope auto` (default) vælger `working-tree`, når arbejdstræet er dirty, ellers branch-diff mod default branch. En mappe uden Git giver `full`.
- Mangler repoet `origin/HEAD` og `main`/`master`/`trunk`, så brug `--base <ref>` eller `--scope full`.
- Tekst efter flagene bliver ét quotet `--focus`-argument, aldrig spliced ind i en shell-kommando.
- Rapporten skrives som `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md` i projektroden.

Eksempler:

```
/llm-peer-review:review
/llm-peer-review:review --scope branch --base main fokuser på fejlhåndtering
/llm-peer-review:adversarial-review --scope full
```

## Brug i Codex

Skill'en virker selvstændigt uden pluginet. Peg Codex på skill-mappen:

```
plugins/llm-peer-review/skills/llm-peer-review
```

Kopiér eller symlink den til Codex' skills-mappe og start med `$llm-peer-review` (se `agents/openai.yaml`). Indgangspunktet er `scripts/run-review.sh`; flow og regler står i `SKILL.md`.

## Krav

`claude`, `agy` (med login eller `ANTIGRAVITY_API_KEY`), `codex`, `git`, `jq`, `python3` (kun stdlib) og `/bin/bash` 3.2+. Modelnavne står kun i `scripts/models.json`.

## Inspireret af

- [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc): plugin-format, commands og dele af review-prompts og skema (Apache-2.0, se `NOTICE`).
- [antigravity-plugin-cc](https://github.com/simplybychris/antigravity-plugin-cc): idéen til `setup`-kommandoen og brugen af `agy`.

## Licens

MIT (se `LICENSE`). Dele af prompts og schema stammer fra openai/codex-plugin-cc (Apache-2.0); se `NOTICE` og `LICENSES/Apache-2.0.txt`.
