# Reviewer hardening

## Indhold

- Fælles isolation
- Claude
- Gemini
- Codex
- Outputkontrakt

## Fælles isolation

Brug samme projektrod, scope og prompt til alle tre stemmer. Kør fra et stabilt
snapshot og brug en privat `mktemp`-mappe med `umask 077`. Hold stdout, stderr og
last-message adskilt. Genbrug aldrig outputstier på tværs af runs.

Modeller skal altid resolves fra `scripts/models.json` gennem `models.sh`.
Hardcodede modelnavne i launch-kommandoer bliver hurtigt stale og kan stille
fjerne en familie fra konsensus.

## Claude

- Sæt `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` for at undgå projektets Claude-memory.
- Tillad kun `Read,Glob,Grep` og forbyd `Agent` og `Task`.
- Brug `--permission-mode dontAsk`, ikke bypass.
- Erstat systemprompten med en single-reviewer-kontrakt.
- Quote modelstrengen; modelnavne kan indeholde shell-globtegn.
- Hold JSON-envelope på stdout og diagnostik på stderr.

## Gemini

`agy` har ikke et tool-level read-only flag. `gemini-review.sh` prepender en
read-only single-reviewer-prompt, validerer at modellen tilhører Gemini-familien,
kontrollerer modelnavnet mod `agy models`, sætter timeout og retry'er én gang.
Kør AGY med `--output-format json`, gem hver rå envelope, udtræk `.response`, og
klassificér kun det udtrukne slutsvar. Intern dialog og tool-events må aldrig
afgive en reviewer-stemme.

`--dangerously-skip-permissions` er nødvendigt for headless drift, men betyder,
at prompten kun instruerer read-only, mens indholdsmanifestet opdager vedvarende ændringer efter kørslen; det er ikke en teknisk skriveblokering. Hvis Gemini
ændrer projektet, er hele review-snapshotet ugyldigt.

Det publicerede Gemini-output er markdown trods det historiske `.json`-suffix.
Brug aldrig `jq` på denne fil. Brug kun `jq` på de bevarede `*.raw.json`-
envelopes ved diagnostik.

Ved slut-gaten skal alle tre publicerede stemmer gå gennem
`extract-review-output.sh`. Helperen afgør formatet fra indholdet: kendte
Claude/AGY-envelopes udtrækkes, mens Gemini/Codex-Markdown videresendes uændret.
Filendelsen må aldrig styre extraction.

## Codex

Brug den lokalt verificerede native CLI-form:

- `--ignore-user-config` for at undgå plugins, MCP og personlige defaults;
- `--model` og `model_reasoning_effort` fra `models.json`;
- `project_doc_max_bytes=0` for at undgå `AGENTS.md`-framing;
- `--sandbox read-only` som tool-level skriveværn;
- `--cd` til den fælles projektrod;
- `--output-last-message` til ren markdown.

Codex genbruger stadig normal `CODEX_HOME`-auth, selv når user config ignoreres.
Brug aldrig `--dangerously-bypass-approvals-and-sandbox` til en review-stemme.

## Outputkontrakt

Alle tre prompts skal kræve:

- konkrete findings med `file:line`;
- severity, reel risiko og konkret fix;
- ingen style/naming;
- en afsluttende `CHECKED:`-attestering;
- `NO_FINDINGS` når reviewet er rent.

`NO_FINDINGS` uden `CHECKED:` er ikke en gyldig ren stemme.
