# Reviewer hardening

## Indhold

- Fælles isolation
- Claude
- Gemini
- Codex
- Outputkontrakt
- Verificeret CLI-adfærd 2026-10-24

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

## Verificeret CLI-adfærd 2026-10-24

Målt live med claude 2.1.309, codex-cli 0.164.0 og agy 1.4.5 på et
throwaway-projekt (`calc.py` med en indført n-1-fejl). Diffen lå i en separat
run-mappe uden for projektet (`$R/target.diff`). Prompt: "Read $R/target.diff,
review calc.py, return JSON per schema". Schema: `schemas/review-output.schema.json`.
Rå output ligger i `scripts/fixtures/`.

### Schemaet

- Claude afviser `"$schema": "https://json-schema.org/draft/2020-12/schema"`:
  `Error: --json-schema is not a valid JSON Schema: no schema with key or ref
  "https://json-schema.org/draft/2020-12/schema"` (exit 1, tom stdout). Derfor
  har schemaet ingen `$schema`-nøgle. Uden nøglen accepterer alle tre CLI'er det.
- `minLength` accepteres af alle tre. `minItems` er ikke brugt.
- Alle tre payloads holdt sig til schemaet. Ingen ekstra felter, korrekte enums,
  `line_*` ≥ 1, `confidence` i 0-1. AGY returnerede `confidence: 1` som heltal.

### Claude

- `--json-schema "$(cat schema)"` sammen med `--output-format json` giver en
  envelope med `.structured_output` (objekt) og `.result` (samme JSON som streng).
  `subtype: "success"`, `is_error: false`, `terminal_reason: "completed"`.
  `stop_reason` er `"tool_use"`, ikke `"end_turn"`. Brug det ikke som fejlsignal.
- Read af `$R/target.diff` uden for cwd virkede under `--permission-mode dontAsk`
  med `--add-dir "$R"`. `permission_denials` var tom, og filen står i `checked`.
- Fixture: `scripts/fixtures/claude-envelope.json` (2 findings).

### Codex

- `--output-schema <fil>` virker i 0.164.0. `--output-last-message` indeholder rå
  JSON uden fence. Samme JSON står på stdout.
- `--sandbox read-only` kunne læse `$R/target.diff` uden for `--cd`. Codex kørte
  også `git` og `python3` read-only for at reproducere fejlen.
- `--ignore-user-config` plus `project_doc_max_bytes=0` isolerer ikke helt.
  Codex læste stadig globale skills under `~/.agents/skills/` og fulgte en
  global instruks om at gemme en Markdown-rapport. Det skrev den selv i
  `summary` ("could not be saved because the workspace is read-only"). Sandboxen
  stoppede det, men prompt-kontaminering fra brugerens globale opsætning er
  stadig mulig.
- Mindste verificerede version-floor for schema-stien: **codex-cli 0.164.0**.
  `models.json` har `min_cli_version` 0.153.4, som ikke er verificeret med
  `--output-schema`.
- Fixture: `scripts/fixtures/codex-last.json` (1 finding).

### AGY (Gemini)

Fælles flag: `agy -p <prompt> --model <models.sh gemini> --output-format json
--json-schema <schemafil> --add-dir "$P" --add-dir "$R" --disable-slash-commands
--print-timeout 300s`, kørt med cwd `$P`. Skriveproben var prompten "Create the
file PROBE.txt containing hi" (uden schema).

| Variant | Ekstra flag | Review headless | `PROBE.txt` opstod |
| --- | --- | --- | --- |
| a | `--dangerously-skip-permissions` | Ja, 46 s, 2 findings | Ja, i `$R` |
| b | `--mode plan --sandbox` | Nej. Tom `.response` | Nej. `write_file` blev afvist |
| c | `--sandbox --dangerously-skip-permissions` | Ja, 89 s, 2 findings | Ja, i `$R` |

- Når skemaet virker, har envelopen `.structured_output` (objekt), `.response`
  (samme JSON som rå streng, **uden** fence) og et ekko af schemaet i
  `.json_schema`.
- Variant b gav `status: "SUCCESS"` og exit 0, selvom `.response` var tom.
  `denied_actions` var `[{"action":"command","display_name":"RunCommand"}]`.
  På stderr stod: `warning: --mode plan has no effect while slash command
  expansion is disabled.` Plan-mode var altså ikke aktiv. Blokeringen kom af,
  at `--dangerously-skip-permissions` manglede, så headless-tilstanden afviste
  alle tools, også læsning via `RunCommand`.
  `status: "SUCCESS"` og exit 0 beviser derfor ikke et
  svar. En tom `.response` eller ikke-tomme `denied_actions` skal regnes som
  fejl.
- `--sandbox` begrænser kun terminalen. AGY's eget `write_file`-tool skriver
  stadig.
- Skriveproben skrev i den **sidste** `--add-dir` (`$R`), ikke i cwd/projektet.
  Hvis run-mappen gives som `--add-dir`, kan en skrivning undgå
  projektmanifestet. Run-mappen bør derfor ikke gives til AGY som `--add-dir`,
  eller den skal også kontrolleres.
- Fixture: `scripts/fixtures/agy-envelope.json` (variant a, 2 findings).

### Beslutning

Regel: vælg den første variant i rækkefølgen b, c, a, som både fuldfører
reviewet og ikke skaber `PROBE.txt`. Ingen variant opfylder begge krav. b
blokerer skrivning, men fuldfører ikke. c og a fuldfører, men skriver.
Fallback-reglen gælder derfor: c fuldførte, så standarden for Task 6 er
**(a) + `--sandbox`**, altså variant c:
`--sandbox --dangerously-skip-permissions`.

Read-only for AGY håndhæves stadig kun af prompten og indholdsmanifestet. Der er
ingen teknisk skriveblokering.
