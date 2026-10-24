# Verdicts og recovery

## Verdicts

| Verdict | Betydning | Handling |
|---|---|---|
| `VALID` | Konkrete findings med locations | Tæl som stemme |
| `CLEAN` | `NO_FINDINGS` plus konkret `CHECKED:` | Tæl som gyldig nul-finding-stemme |
| `MISFIRE` | Reviewer roleplayede orchestrator | Relaunch én gang med ny run-mappe |
| `CAPACITY` | Auth, quota, netværk eller modelkapacitet | Kontrollér CLI/auth og relaunch én gang |
| `REFUSED` | Gemini over-refusal | Wrapperen neutral-reframer én gang; prøv derefter evt. anden Gemini-tier |
| `ERROR` | CLI- eller envelope-fejl | Læs `.err`, ret årsagen og relaunch én gang |
| `WEAK` | Ikke nok location-signal eller attestering | Inspicér rå output; relaunch hvis kontrakten mangler |
| `EMPTY` / `MISSING` | Intet brugbart output | Kontrollér PID, sti og stderr |

En stemme, der stadig ikke er `VALID` eller `CLEAN` efter én relaunch, markeres
som manglende. Dens tavshed må aldrig bruges som enighed.

## Hyppige fejl

- **Output blandet med stderr:** brug separate filer; ellers fejler JSON og classify.
- **Samme outputsti genbrugt:** stop gammel proces og opret en ny privat run-mappe.
- **Forkert model trods succes:** resolv alle modeller med `models.sh`; Codex skal
  også have eksplicit `--model` og reasoning override.
- **Kendt model afvises fra `agy models`:** nogle AGY-versioner viser
  `model-id\\tlabel` med bogstavelig `\\t`. Wrapperen skal udtrække det førende
  tekniske `gemini-*`-ID og matche dét eksakt, ikke hele visningslinjen.
- **Reviewer-scope varierer:** brug én fælles prompt; sammenlign ikke full-tree med
  diff-only som om de var ligeværdige stemmer.
- **`AGENTS.md` eller anden memory overtager rollen:** brug de isolationsflags,
  der står i hardening-referencen.
- **Gemini-fil køres gennem `jq`:** den er markdown, ikke JSON.
- **Slut-gaten afviser en VALID Gemini `.json`:** brug
  `extract-review-output.sh`; den opdager publiceret Markdown fra indholdet og
  bruger kun envelope-udtræk, når filen faktisk er en kendt JSON-envelope.
- **`CLEAN` fejltolkes som `WEAK`:** kræv både `NO_FINDINGS` og `CHECKED:`.
- **Multiline `CHECKED:` fejltolkes:** en efterfølgende Markdown-liste er gyldig;
  kør classifier-fixtures, hvis den stadig bliver `WEAK`.
- **Intern AGY-dialog giver falsk `VALID`:** kontrollér `attemptN.raw.json`, men
  klassificér kun `attemptN.final.md`, som skal være udtrukket fra `.response`.
- **Et retry overskriver evidens:** behold `attemptN.raw.json`,
  `attemptN.final.md`, `attemptN.err` og `attemptN.classify.txt` for hvert forsøg.
- **Reviewprocessen er væk, men output er tomt:** læs den tilhørende `.err` og
  kontrollér auth/model før relaunch.

## For gammel Codex CLI

Kør `python3 "$SCRIPTS/resolve-codex.py"` i preflight og brug den returnerede
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
CODEX_BIN="$(python3 "$SCRIPTS/resolve-codex.py")" || exit 1
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
