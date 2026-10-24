# Verdicts og recovery

## Verdicts

Gyldighed afgøres af JSON-skemaet (`review_json.py`), ikke af tekstmønstre. Se
`verdicts.txt` i run-mappen for hver stemmes verdict.

| Verdict | Betydning | Handling |
|---|---|---|
| `VALID` | Skema-gyldigt JSON med mindst én finding | Tæl som stemme |
| `CLEAN` | Skema-gyldigt: `approve`, 0 findings og ikke-tom `checked` | Tæl som gyldig nul-finding-stemme |
| `WEAK` | Ikke skema-gyldigt JSON (eller `needs-attention` uden findings, eller ukendelig prosa) | Inspicér rå output; relaunch én gang |
| `ERROR` | CLI- eller envelope-fejl (fx `is_error`, agy ikke `SUCCESS`) | Læs `.err`, ret årsagen og relaunch én gang |
| `MISFIRE` | Reviewer roleplayede orchestrator | Relaunch én gang (ny run-mappe) |
| `CAPACITY` | Auth, quota, netværk eller modelkapacitet | Kontrollér CLI/auth og relaunch én gang |
| `REFUSED` | Gemini over-refusal | Wrapperen genformulerer neutralt én gang; relaunch derefter højst én gang |
| `EMPTY` / `MISSING` | Intet brugbart output (under 40 bytes / filen findes ikke) | Kontrollér PID, sti og stderr |

Kun `VALID` og `CLEAN` tæller. En stemme, der stadig ikke er gyldig efter ét
relaunch, markeres som manglende (`MANGLER (...)` i `aggregate.md`). Dens
tavshed må aldrig bruges som enighed. Relaunch-opskriften står i SKILL.md §4.

## Exitkoder fra run-review.sh

- **`2`:** preflight (manglende CLI, `jq`, `agy`-auth, ingen kompatibel Codex),
  forkert argument, run-mappe inde i projektet, watcher-fejl eller timeout.
  Stemmernes processer er stoppet, og der er ingen `aggregate.md`. Læs stderr.
- **`3`:** `prepare_review.py` fandt intet at reviewe. Brug `--scope full` eller
  `--base <ref>`.
- **`4`:** snapshot-diffen er ikke tom. Find årsagen (editor, formatter,
  watcher-proces, en reviewer der skrev) og kør alle stemmer igen.
- **`130`/`143`:** afbrudt; run-mappen er bevaret.

## Hyppige fejl

- **`auto` fejler på et rent træ:** repoet har hverken `origin/HEAD` eller
  `main`/`master`/`trunk`. Giv `--base <ref>` eller `--scope full`.
- **Output blandet med stderr:** brug separate filer; ellers fejler JSON og classify.
- **Forkert model trods succes:** modeller kommer kun fra `models.json` via
  `models.sh`; Codex får også eksplicit `--model` og reasoning override.
- **Kendt model afvises fra `agy models`:** nogle AGY-versioner viser
  `model-id\\tlabel` med bogstavelig `\\t`. Wrapperen skal udtrække det førende
  tekniske `gemini-*`-ID og matche dét eksakt, ikke hele visningslinjen.
- **Reviewer-scope varierer:** alle stemmer får samme `shared/prompt.md` og
  `shared/target.diff`; sammenlign ikke full-tree med diff-only.
- **`AGENTS.md`, `GEMINI.md` eller anden memory overtager rollen (`MISFIRE`):**
  se isolationsafsnittene i [hardening](hardening.md). Codex indlæser stadig
  `~/.agents/skills` og `~/.codex/AGENTS.md`; `MISFIRE` er nettet.
- **Model returnerer JSON i en ```` ```json ````-fence:** er gyldigt og klassificeres
  normalt. Kun ét fence om hele objektet accepteres.
- **`WEAK` på et svar der ligner et review:** valider mod
  `schemas/review-output.schema.json` (`python3 -I scripts/review_json.py classify <fil>`):
  ekstra felter, forkert enum, `line_*` under 1 eller `confidence` uden for 0-1
  giver `WEAK`.
- **Samme fund står som flere klynger:** `aggregate.md` slår kun sammen på
  normaliseret sti og nærliggende linjer; flet semantisk ens klynger manuelt (§5).
- **Intern AGY-dialog giver falsk `VALID`:** kontrollér `attemptN.raw.json`, men
  klassificér kun `attemptN.final.md`, der er udtrukket fra envelopen.
- **Et retry overskriver evidens:** hvert forsøg beholder `attemptN.raw.json`,
  `attemptN.final.md`, `attemptN.err` og `attemptN.classify.txt`.
- **Tom `.response` fra agy trods `SUCCESS`:** regn det som fejl; tjek
  `denied_actions` og stderr (se [hardening](hardening.md)).
- **Reviewprocessen er væk, men output er tomt:** læs den tilhørende `.err` og
  kontrollér auth/model før relaunch.

## For gammel Codex CLI

Kør `python3 -I "$SKILL_DIR/scripts/resolve-codex.py"` i preflight og brug den returnerede
absolutte sti som `"$CODEX_BIN" exec`. Helperen kontrollerer PATH, faste
installationsmapper, npm-pakkens native binær og app-CLI'er med `--version`
(højst fem sekunder pr. kandidat). Den frasorterer gamle, ukendte og
prerelease-versioner og ændrer hverken PATH, installationer eller modeller.

Hvis ingen kandidat består, ret den vedvarende installation som del af en
autoriseret CLI-opdatering. Undgå gentagne engangsinstallationer i `/tmp` og
sænk ikke versionsgrænsen for at få en gammel CLI igennem. Find først ejeren
med `ls -l /absolut/sti/codex`; opdater med samme pakkemanager. For den lokale
npm-installation under `/opt/homebrew` er kommandoen:

```bash
/opt/homebrew/bin/npm install --global @openai/codex@latest
CODEX_BIN="$(python3 -I "$SKILL_DIR/scripts/resolve-codex.py")" || exit 1
"$CODEX_BIN" --version
```

Dette er en særskilt, vedvarende opdatering; resolveren installerer aldrig
software automatisk under et review. Alternativt kan en eksisterende,
kompatibel CLI vælges med `PEERREVIEW_CODEX_BIN`. Revurdér versionsgrænsen
ved et senere modelskift; versionstjekket beviser ikke modeladgang på kontoen.

## Codex-auth

Hvis native Codex returnerer 401, invalidated token eller sign-in-fejl, brug den
lokale Codex-loginmekanisme og verificér auth, før stemmen køres igen. Erstat ikke
OpenAI-familien med en ekstra Claude- eller Gemini-model.

## Manglende familie

Hvis en familie ikke kan levere efter én kontrolleret relaunch, fortsæt kun hvis
brugeren accepterer den reducerede dækning eller opgaven tillader best-effort.
Rapportér tydeligt:

1. hvilken familie der mangler;
2. sidste verdict og fejlårsag;
3. at 2-stemmers konsensus er svagere;
4. hvilke single-reviewer findings der derfor kræver ekstra manuel evidens.
