# Reviewer hardening

Launch-flagene for alle tre stemmer står udelukkende i `scripts/run-review.sh`
(Claude, Codex) og `scripts/gemini-review.sh` (Gemini). Se dem dér; denne fil
forklarer hvorfor, og hvad der er målt.

## Indhold

- Fælles isolation
- Outputkontrakt (schema)
- Claude
- Gemini
- Codex
- Verificeret CLI-adfærd 2026-10-24

## Fælles isolation

Alle stemmer får samme projektrod, scope og prompt. `run-review.sh` opretter en
privat `mktemp`-mappe (`llm-peer-review.XXXXXX`, `umask 077`) uden for projektet
og afviser en run-mappe inde i projektroden. Stdout, stderr og last-message
holdes adskilt, og outputstier genbruges aldrig på tværs af runs.

Diff og prompt ligger i `shared/` i run-mappen (`target.diff`, `prompt.md`).
Kun `shared/` gives til reviewerne som ekstra læsbar mappe, aldrig hele
run-mappen. Efter prepare gøres `shared/` read-only (`chmod -R a-w`), og en
sha256 pr. fil gemmes i `shared.sha256`. Ejeren kan stadig `chmod` tilbage eller
erstatte mappen, så checksummen er selve kontrollen: den tjekkes igen ved siden
af snapshotet, både efter en normal kørsel og efter watcher-fejl/timeout, og en
forskel giver exit `4`.

Read-only er en invariant, som scriptet tjekker: `snapshot.py` tager et
indholdsmanifest før reviewet (før prepare) og efter. Manifestet dækker tracked
og ikke-ignorerede untracked filer, filtilstand og Git-tilstand (HEAD, index,
status) samt Git-kontrolfilerne `HEAD`, `config`, `config.worktree`,
`packed-refs` (kun lokale refs), `hooks/**`, `info/**`, `refs/heads/**` og `refs/tags/**` i både git-dir og common-dir
(så linked worktrees, hvor `.git` er en fil, også er dækket). En forskel giver
exit `4` og ingen aggregering. Inden snapshotet stoppes alle stemmers
procestræer altid, også efter en normal afslutning, så en efterladt
efterkommer ikke kan skrive efter `snapshot.after`.

Alle git-kald i `snapshot.py` og `prepare_review.py` kører med
`-c core.fsmonitor=false -c core.hooksPath=/dev/null`, så en plantet fsmonitor
eller hook ikke udføres af scriptets egne git-kald. `git diff` kører desuden med
`--no-ext-diff --no-color --no-textconv`, så brugerens git-config ikke kan
ændre `target.diff`.

Det er en efterkontrol, ikke skrivebeskyttelse. Manifestet dækker **ikke**:

- en ændring, som gendannes under kørslen;
- ignorerede filer (`.gitignore`, `info/exclude`);
- filer uden for projektet, fx AGY's plan-artefakter i
  `~/.gemini/antigravity-cli/brain/` eller andre stier i `$HOME`;
- `.git/objects`, logs og andre git-filer uden for listen ovenfor;
- git-filter-drivere (`filter.<navn>.clean` i `.git/config` plus
  `.gitattributes`): en stemme, der planter en, opdages (config er hashet),
  men efter-snapshottets `git status` kan allerede have kørt den.

`refs/remotes`, `FETCH_HEAD` og fjern-refs i `packed-refs` hashes bevidst ikke:
de ændres af ethvert `git fetch` (fra brugeren eller en IDE) og er ikke en
reviewers skrivning.

`run-review.sh` fjerner relative `PATH`-indgange (`""`, `.`, `bin` osv.) ved start,
fordi CLI'erne slås op efter `cd "$PROJECT_ROOT"`; ellers kunne projektet levere
sin egen `claude`, `git` eller `jq`. `resolve-codex.py` ignorerer også relative
indgange.

Modeller resolves altid fra `scripts/models.json` gennem `models.sh`.
Hardcodede modelnavne bliver hurtigt stale og kan stille fjerne en familie fra
konsensus. Ingen andre filer må indeholde modelnavne.

## Outputkontrakt (schema)

Alle tre stemmer skal returnere JSON efter `schemas/review-output.schema.json`
(`verdict`, `summary`, `findings`, `checked`, `next_steps`). Klassifikationen
afgøres af skemaet, ikke af tekstmønstre:

- `VALID`: skema-gyldigt med mindst én finding.
- `CLEAN`: skema-gyldigt, `verdict` `approve`, nul findings og ikke-tom `checked`.
- `WEAK`: ikke skema-gyldigt JSON (eller `needs-attention` uden findings).
- `ERROR`: CLI- eller envelope-fejl.

En enkelt ```` ```json ````-fence om objektet accepteres. Regexes bruges kun til
at genkende fejl-, afvisnings- og orchestrator-roleplay-tekster, der slet ikke
er JSON (`CAPACITY`, `REFUSED`, `MISFIRE`). Schemaet har bevidst ingen
`$schema`-nøgle (se den målte adfærd nedenfor).

## Claude

- `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` undgår projektets Claude-memory;
  `--setting-sources user` undgår projekt- og lokale settings.
- `--strict-mcp-config` uden `--mcp-config` starter stemmen uden MCP-servere
  (brugerens og projektets `.mcp.json` ignoreres).
- `--safe-mode` slår brugerens customizations fra (installerede plugins' skills,
  hooks, MCP, CLAUDE.md, custom commands). Målt 2026-10-25 med Claude Code
  2.1.309 via `--output-format stream-json` init-eventet: uden flaget kørte to
  SessionStart-hooks, med flaget ingen. Skills faldt fra 102 til 19 og
  slash-commands fra 138 til 55, mens tools (`Glob, Grep, Read`) og MCP (`[]`) var
  uændrede. Et live review med `--json-schema` gav `VALID`. Init-listen viser
  stadig plugin-navnene (n=1-måling; genmål efter en Claude Code-opgradering).
  `--restricted` er ikke evalueret.
- Kun `Read,Glob,Grep`; `Agent` og `Task` er forbudt.
- `--permission-mode dontAsk`, aldrig bypass.
- Systemprompten erstattes af en single-reviewer-kontrakt, så revieweren ikke
  tror, den er orkestrator.
- Skemaet gives med `--json-schema`; resultatet læses fra `.structured_output`.
- `--add-dir` gives kun til `shared/`, så diffen kan læses uden for cwd.
- Quote modelstrengen; modelnavne kan indeholde shell-globtegn.
- JSON-envelope på stdout og diagnostik på stderr.

## Gemini

`agy` har ikke et tool-level read-only flag, og `--dangerously-skip-permissions`
er nødvendigt for headless drift. Read-only er derfor et workflow, ikke en
teknisk skriveblokering. `gemini-review.sh`:

- prepender en read-only single-reviewer-prompt;
- validerer, at modellen er et `gemini-*` ID, og kontrollerer det mod `agy models`;
- kører `agy` med `--mode plan --sandbox --dangerously-skip-permissions`
  (variant d nedenfor), og **uden** `--disable-slash-commands`, som stille
  deaktiverer plan-mode;
- giver `--output-format json` og `--json-schema`, gemmer hver rå envelope og
  klassificerer kun det udtrukne slutsvar (`.structured_output`, ellers `.response`);
- retry'er højst én gang; ved `REFUSED` genformuleres prompten neutralt;
- sætter en timeout pr. forsøg (`GEMINI_ATTEMPT_CAP`, standard 900 s).

**`--add-dir`-rækkefølge:** AGY skriver relative stier i den **sidste**
`--add-dir`. Projektmappen (cwd) skal derfor altid være sidst, så en skrivning
havner i det manifest-kontrollerede træ. Run-mappen gives aldrig som
`--add-dir`; kun `shared/` gives, før projektet.

Hvis Gemini ændrer projektet, er hele review-snapshotet ugyldigt (exit `4`).
Intern AGY-dialog og tool-events må aldrig afgive en reviewer-stemme.
`status: "SUCCESS"` og exit 0 beviser ikke et svar; en tom `.response` (uden
`.structured_output`) er en fejl. Ikke-tomme `denied_actions` er en advarsel, der
skal inspiceres i `attemptN.raw.json`; svaret afvises ikke af den grund.

## Codex

Den lokalt verificerede native CLI-form (flagene står i `run-review.sh`):

- `--ignore-user-config` mod plugins, MCP og personlige defaults;
- `--model` og `model_reasoning_effort` fra `models.json`;
- `project_doc_max_bytes=0` mod `AGENTS.md`-framing;
- `--sandbox read-only` som tool-level skriveværn;
- `--cd` til den fælles projektrod;
- `--output-schema` og `--output-last-message` til rå JSON.

Codex genbruger stadig normal `CODEX_HOME`-auth. Brug aldrig
`--dangerously-bypass-approvals-and-sandbox` til en review-stemme.

**Kendt begrænsning:** trods `--ignore-user-config` og `project_doc_max_bytes=0`
indlæser Codex stadig `~/.agents/skills` og `~/.codex/AGENTS.md`. Brugerens
globale opsætning kan derfor forurene prompten (se målingen nedenfor).
`MISFIRE`-klassifikationen er nettet: en stemme, der spiller orchestrator,
kasseres og relaunches højst én gang.

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
  stadig mulig. `MISFIRE` er nettet (se Codex-afsnittet ovenfor).
- Mindste verificerede version-floor for schema-stien: **codex-cli 0.164.0**.
  `models.json` har `min_cli_version` 0.164.0 (hævet fra 0.153.4, som ikke var
  verificeret med `--output-schema`).
- Fixture: `scripts/fixtures/codex-last.json` (1 finding).

### AGY (Gemini)

Fælles flag for a-c: `agy -p <prompt> --model <models.sh gemini> --output-format
json --json-schema <schemafil> --add-dir "$P" --add-dir "$R"
--disable-slash-commands --print-timeout 300s`, kørt med cwd `$P`. Variant d
bruger de samme flag, men **uden** `--disable-slash-commands` og med omvendt
rækkefølge: `--add-dir "$R" --add-dir "$P"`, så projektet er sidst.
Skriveproben var prompten "Create the file PROBE.txt containing hi" (uden
schema).

| Variant | Ekstra flag | Review headless | `PROBE.txt` opstod |
| --- | --- | --- | --- |
| a | `--dangerously-skip-permissions` | Ja, 46 s, 2 findings | Ja, i `$R` |
| b | `--mode plan --sandbox` | Nej. Tom `.response` | Nej. `write_file` blev afvist |
| c | `--sandbox --dangerously-skip-permissions` | Ja, 89 s, 2 findings | Ja, i `$R` |
| d | `--mode plan --sandbox --dangerously-skip-permissions` | Ja, 89 s, 2 findings | Nej, hverken i `$P` eller `$R` |

- Når skemaet virker, har envelopen `.structured_output` (objekt), `.response`
  (samme JSON som rå streng, **uden** fence) og et ekko af schemaet i
  `.json_schema`.
- Variant b gav `status: "SUCCESS"` og exit 0, selvom `.response` var tom.
  `denied_actions` var `[{"action":"command","display_name":"RunCommand"}]`.
  På stderr stod: `warning: --mode plan has no effect while slash command
  expansion is disabled.` Plan-mode var altså ikke aktiv. Formodentlig kom
  blokeringen af, at `--dangerously-skip-permissions` manglede, så headless-
  tilstanden afviste tools, der krævede tilladelse. Det er en slutning ud fra
  `denied_actions` og stderr: kun `RunCommand` (review) og `WriteFile` (probe)
  blev faktisk observeret afvist.
  `status: "SUCCESS"` og exit 0 beviser derfor ikke et
  svar. En tom `.response` skal regnes som fejl; ikke-tomme `denied_actions`
  er en advarsel, der skal inspiceres (se Gemini-afsnittet).
- `--sandbox` begrænser kun terminalen. AGY's eget `write_file`-tool skriver
  stadig.
- Skriveproben skrev i den **sidste** `--add-dir` (`$R`), ikke i cwd/projektet.
  Hvis run-mappen gives som `--add-dir`, kan en skrivning undgå
  projektmanifestet. Projektmappen skal derfor altid være den **sidste**
  `--add-dir`. Run-mappen bør helst slet ikke gives til AGY som `--add-dir`, og
  ellers skal den også kontrolleres.
- Variant d (plan-mode aktiv): reviewet fuldførte med samme envelope-struktur
  som a (samme top-level nøgler, `.response` er rå JSON uden fence,
  `denied_actions` er fraværende). Ved skriveproben skrev agenten ikke filen.
  Den svarede med en implementeringsplan og bad om godkendelse ("Once approved,
  I will proceed"). Planen lå i AGY's egen tilstandsmappe
  `~/.gemini/antigravity-cli/brain/<conversation_id>/create_probe_file.md`, uden
  for `$P` og `$R`. Der var ingen `denied_actions`. Spærringen er altså plan-
  mode-workflowet, ikke en verificeret afvisning i tool-laget.
  Plan-mode skriver altså sine plan-artefakter til
  `~/.gemini/antigravity-cli/brain/…`, som ligger uden for indholdsmanifestet.
  Det er en skrivesti ud af projektet, som manifestet ikke kan se; den kan ikke
  lukkes herfra, kun noteres.
- Fixture: `scripts/fixtures/agy-envelope.json` (variant a, 2 findings). Envelopen
  fra d er strukturelt identisk, så der er ingen separat fixture.

### Beslutning

Første runde: vælg den første variant i rækkefølgen b, c, a, som både
fuldfører reviewet og ikke skaber `PROBE.txt`. Ingen variant opfyldte begge
krav. b blokerer skrivning, men fuldfører ikke. c og a fuldfører, men skriver.
Fallback-reglen ("hvis ingen variant blokerer skrivning") er læst som "hvis
ingen *brugbar* variant blokerer skrivning", fordi b slet ikke kan levere et
review. Dermed blev c (= a + `--sandbox`) foreløbig standard.

b var konfunderet (plan-mode inaktiv, ingen skip-permissions), så d blev kørt
bagefter. d fuldførte reviewet, og `PROBE.txt` opstod hverken i `$P` eller
`$R`. **Standarden for Task 6 er derfor variant d**:
`--mode plan --sandbox --dangerously-skip-permissions`, med projektmappen som
sidste `--add-dir`. `--disable-slash-commands` skal **fjernes** fra AGY-kaldet,
fordi plan-mode ellers ikke har nogen effekt. c er fallback.

Plan-mode stopper skrivning i workflowet, men det er ikke en verificeret
skriveblokering i tool-laget. Indholdsmanifestet er stadig obligatorisk.

**Evidensgrundlag:** beslutningen for variant d hviler på **ét** review og
**ét** skriveprobe (n=1). Den er ikke gentaget og kan ændre sig mellem
agy-versioner. Genmål ved en agy-opgradering og forvent aldrig, at plan-mode
alene beskytter projektet.
