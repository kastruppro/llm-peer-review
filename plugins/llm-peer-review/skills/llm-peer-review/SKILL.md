---
name: llm-peer-review
description: >-
  Kør tre uafhængige, parallelle LLM-reviews (Claude, Gemini, Codex) af et diff,
  en branch eller hele kodebasen, valider hvert svar mod et JSON-skema, og
  aggregér kun gyldige stemmer til en evidensbaseret konsensus. Brug når
  brugeren beder om triple review, tre-LLM review, diff- eller branch-review,
  adversarial review, en grundig pre-merge audit eller en uafhængig
  multi-model vurdering før eventuelle rettelser.
---

# LLM peer review

Tre reviewere (Claude CLI, Gemini via Antigravity CLI `agy`, native Codex CLI)
læser det samme stabile snapshot og returnerer JSON efter
`schemas/review-output.schema.json`. `scripts/run-review.sh` er det eneste
indgangspunkt: preflight, scope, parallel kørsel, watcher, read-only-kontrol,
klassifikation og aggregering. Launch-flag og modeller står kun i scripts og
`scripts/models.json`; opfind aldrig egne kald.

## 1. Ufravigelige regler

1. Ændr ikke projektfiler, git-state eller instruktioner, mens reviewerne kører.
2. Giv alle stemmer samme scope og samme kerneprompt.
3. Kun schema-gyldige `VALID`/`CLEAN` tæller som stemme. Tavshed og fejl er ikke enighed.
4. Verificér single-reviewer findings direkte i kildekoden før de accepteres.
5. Ret kun kode efter aggregering, og kun hvis brugeren vælger det (regel 7).
6. Reviewerne er read-only. Gemini har kun workflow-baseret read-only, så
   indholdsmanifestet før/efter (exit `4`) er obligatorisk.
7. Efter rapporten: STOP og spørg brugeren, hvilke findings der skal rettes.
   Ret aldrig automatisk, heller ikke når rettelsen er oplagt.

Brug ikke skill'en til små diffs, lint/style eller en kodebase, der aktivt
ændres. En enkelt reviewer er billigere dér.

## 2. Vælg scope og mode

Default er `--scope auto`: dirty arbejdstræ giver `working-tree`, ellers
branch-diff mod default branch; uden Git bliver det `full`.

| Brugeren vil | Flags |
|---|---|
| review af det jeg har ændret / "review" uden mere | ingen (`auto`) |
| kun ucommittede ændringer | `--scope working-tree` |
| hele branchen / PR mod en bestemt base | `--scope branch --base <ref>` |
| hele kodebasen, pre-merge audit | `--scope full` |
| udfordr design og antagelser | `--adversarial` |
| styr opmærksomheden | `--focus "$FOCUS"` (ét argument, se nedenfor) |
| kun nogle stemmer | `--voices claude,codex` |

Fokustekst er data, aldrig kode. Dobbelte anførselstegn udvider stadig `$(...)`,
backticks og `$VAR`, så læg teksten ordret i en variabel via en quotet heredoc og
send den som ét argument; den udføres eller fortolkes aldrig:

```bash
FOCUS=$(cat <<'PEER_FOCUS_EOF'
<fokustekst ordret>
PEER_FOCUS_EOF
)
# ... --focus "$FOCUS"
```

`--scope` skal være `auto|working-tree|branch|full`, og `--base` et almindeligt
ref-navn uden mellemrum eller shell-metategn (ellers spørg brugeren).

Mangler repoet `origin/HEAD` og `main`/`master`/`trunk`, fejler `auto` på et
rent træ med besked om `--base` eller `--scope full`. Vælg da en af dem.

## 3. Kør

`SKILL_DIR` er den absolutte mappe med denne `SKILL.md`; `PROJECT_ROOT` er
`pwd -P` for projektet (stier med mellemrum er understøttet, quote altid):

```bash
bash "$SKILL_DIR/scripts/run-review.sh" --root "$PROJECT_ROOT" [flags]
```

- **Claude Code:** `Bash` med `run_in_background: true` og `timeout: 2400000`.
  Fortæl brugeren, at reviewet kører (watcherens grænse er 35 min), og rør ikke projektet.
  Læs resultatet, når baggrundskørslen melder færdig.
- **Codex:** kør i forgrunden med lang yield; send korte statusbeskeder.

Første stdout-linje er `REVIEW_DIR=<sti>`; senere kommer `TARGET=…`, verdicts og
`AGGREGATE=<sti>/aggregate.md`. Scriptet sletter aldrig run-mappen.

| Exit | Betydning | Handling |
|---|---|---|
| `0` | alle valgte stemmer `VALID`/`CLEAN` | gå til §5 |
| `1` | mindst én stemme mangler/er ugyldig; `aggregate.md` findes | §4, derefter §5 |
| `2` | preflight, wiring, watcher-fejl eller timeout; ingen aggregering | læs stderr, ret årsagen ([troubleshooting](references/troubleshooting.md)) |
| `3` | intet at reviewe | foreslå `--scope full` eller `--base <ref>` |
| `4` | projektet ændrede sig under kørslen; ingen aggregering | find årsagen, kør alle stemmer igen på et stabilt snapshot |
| `130`/`143` | afbrudt; stemmerne er stoppet | spørg brugeren, om der skal køres igen |

Watcher-grænser kan justeres med `REVIEW_POLL_INTERVAL`, `REVIEW_MAX_ITER` og
`REVIEW_STALE_ITERS` (se headeren i `run-review.sh`).

## 4. Ved manglende voice

Læs `verdicts.txt` i run-mappen og fejlårsagen i stemmens `.err` (se
[troubleshooting](references/troubleshooting.md)). Relaunch højst én gang pr.
stemme, med samme scope/`--base`/`--focus`/`--adversarial` og kun den manglende
voice. Det giver en ny run-mappe:

```bash
bash "$SKILL_DIR/scripts/run-review.sh" --root "$PROJECT_ROOT" --voices gemini [samme flags]
```

Kræv derefter, at projektet var uændret mellem de to runs, og aggregér på tværs
(`OLD`/`NEW` er de to `REVIEW_DIR`, `*_RID` er mappernes basename):

```bash
diff -u "$OLD/snapshot.before.json" "$NEW/snapshot.before.json" \
  && python3 -I "$SKILL_DIR/scripts/review_json.py" aggregate --root "$PROJECT_ROOT" \
       claude="$OLD/review_claude_$OLD_RID.json" \
       gemini="$NEW/review_gemini_$NEW_RID.json" \
       codex="$OLD/review_codex_$OLD_RID.last.md"
```

Ikke-tom diff betyder, at runs ikke kan blandes: kør alle stemmer igen. En
stemme, der stadig ikke er gyldig efter ét relaunch, står som manglende (en
fil, der ikke findes, giver `MANGLER (MISSING)`). Erstat aldrig familien med en
anden model.

## 5. Verificér

Læs hver klynge i `aggregate.md` mod kildekoden, ikke kun beskrivelsen.

- Klynger med flere stemmer: konsensus, men bekræft stadig stedet.
- Klynger med én stemme: bekræft eller afvis med konkret evidens (kode, kald, test).
- Semantisk ens klynger, som scriptet ikke slog sammen (andre linjer/ordlyd), flettes.
- `CLEAN` er en gyldig nul-finding-stemme, ikke en finding.

## 6. Rapportér

Skriv `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md` i projektroden. Agent og
model er orkestratorens egne, med små bogstaver, mellemrum erstattet af `_` og
versionspunktummer bevaret (fx `CODE_REVIEW_2026-10-24_claude_opus_5.5.md`).

- Manglende voices øverst: familie, sidste verdict og årsag; skriv at tilliden er lavere.
- Findings først, sorteret efter severity (critical, high, medium, low), med
  disposition (accepteret/afvist) og evidens.
- `file:line` ordret som reviewerne rapporterede, og bevar markeringer af
  inferens, usikkerhed og åbne spørgsmål. Ingen nye findings uden kilde.
- Ingen findings: sig det eksplicit og hold restrisiko kort.

Gentag indholdet i svaret og STOP derefter. Spørg, hvilke findings der skal
rettes (AskUserQuestion i Claude Code; ellers en direkte spørgsmålsbesked).
Rør ingen filer, før brugeren har svaret.

## 7. Ryd op

Run-mappen ligger uden for projektet. Ryd kun mappen, dette flow selv oprettede,
og først når rapporten er skrevet (og eventuelle rå outputs er gemt efter
brugerens ønske):

```bash
if [ -f "$REVIEW_DIR/.llm-peer-review-owned" ]; then
  rm -rf -- "$REVIEW_DIR"
else
  echo "Refusing cleanup: ownership marker missing: $REVIEW_DIR" >&2
fi
```

## Ressourcer

- `scripts/run-review.sh`: indgangspunkt, flags, exitkoder, run-mappens layout.
- `scripts/review_json.py`, `scripts/classify-review.sh`: schema-validering, verdicts, aggregering.
- `scripts/models.json`: eneste sted med modelnavne.
- `prompts/review.md`, `prompts/adversarial-review.md`: reviewer-prompts (engelsk).
- [references/hardening.md](references/hardening.md): isolation, målt CLI-adfærd, rationale.
- [references/troubleshooting.md](references/troubleshooting.md): verdicts og fejl.
