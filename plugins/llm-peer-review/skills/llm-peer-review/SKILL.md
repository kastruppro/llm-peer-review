---
name: llm-peer-review
description: >-
  Kør tre uafhængige, parallelle code reviews med modeller fra Anthropic,
  Google og OpenAI, klassificér hvert output og aggregér kun gyldige stemmer
  til en evidensbaseret konsensus. Brug når brugeren beder om triple review,
  tre-LLM review, en grundig pre-merge audit af en hel kodebase eller en
  uafhængig multi-model vurdering før eventuelle rettelser.
---

# Triple review

Kør Claude CLI, Gemini via Antigravity CLI (`agy`) og native Codex CLI mod det
samme stabile snapshot. Vent på alle tre, verificér outputtene, og aggregér først
derefter findings.

## Ufravigelige regler

1. Ændr ikke projektfiler, git-state eller instruktioner, mens reviewerne kører.
2. Giv alle tre stemmer samme scope og samme kerneprompt.
3. Tæl kun `VALID` eller `CLEAN` som en stemme. Tavshed og fejl er ikke enighed.
4. Verificér single-reviewer findings direkte i kildekoden før de accepteres.
5. Ret kun kode efter aggregering, og kun hvis brugerens opgave autoriserer fixes.
6. Kør alle reviewere read-only. Gemini har kun prompt-baseret read-only, så
   sammenlign indholdsmanifest før og efter reviewerne.

Brug ikke denne skill til små diffs, lint/style eller en kodebase, der aktivt
ændres. En enkelt reviewer eller projektets normale review-flow er billigere dér.

## Ressourcer

- `scripts/snapshot.py`: hash reviewets tracked/untracked filer og Git-tilstand; kræver Python 3.
- `scripts/models.json`: kanonisk modelvalg for alle tre familier.
- `scripts/models.sh`: resolv modeller og reasoning uden hardcodede strenge.
- `scripts/resolve-codex.py`: vælg og versionskontrollér en installeret Codex CLI.
- `scripts/guard-review-model.sh`: Claude Code PreToolUse-guard mod stale/hardcodede Claude-modeller; kun aktiv hvor hooket er registreret.
- `scripts/gemini-review.sh`: valider og kør Gemini-stemmen med retry.
- `scripts/extract-agy-response.sh`: udtræk kun AGY-envelopeens endelige svar.
- `scripts/extract-review-output.sh`: udtræk slutstemmer efter indhold, aldrig suffix.
- `scripts/classify-review.sh`: returnér `VALID`, `CLEAN`, `MISFIRE`,
  `CAPACITY`, `REFUSED`, `ERROR`, `WEAK`, `EMPTY` eller `MISSING`.
- `scripts/test-*.sh`: regressionstest extraction, location, retry og precedence.
- `scripts/wait-for-reviewers.sh`: poll alle tre PIDs og verdict alle outputs.
- [references/hardening.md](references/hardening.md): CLI-isolation og rationale.
- [references/troubleshooting.md](references/troubleshooting.md): verdicts og fejl.

Sæt `SKILL_DIR` til den absolutte mappe, der indeholder denne `SKILL.md`.
Kør trin 2-6 i den samme vedvarende shellsession; variabler og PIDs overlever
ikke mellem uafhængige engangskald.

## 1. Kontrollér scope og snapshot

Kør fra projektroden og registrér status uden at ændre den:

```bash
PROJECT_ROOT="$(pwd -P)"
git status --short
git rev-parse --verify HEAD 2>/dev/null || true
```

En dirty worktree er tilladt, hvis den er den tilsigtede review-snapshot. Gem
et indholdsmanifest og sammenlign det efter alle reviewere. Stash, commit eller formatér ikke.

## 2. Preflight og modeller

```bash
SCRIPTS="$SKILL_DIR/scripts"
command -v claude
command -v agy
command -v jq
command -v python3
"$SCRIPTS/models.sh" check

CLAUDE_MODEL="$("$SCRIPTS/models.sh" claude)"
CLAUDE_EFFORT="$("$SCRIPTS/models.sh" claude effort)"
GEMINI_MODEL="$("$SCRIPTS/models.sh" gemini)"
CODEX_MODEL="$("$SCRIPTS/models.sh" codex)"
CODEX_EFFORT="$("$SCRIPTS/models.sh" codex effort)"
CODEX_BIN="$(python3 "$SCRIPTS/resolve-codex.py")" || exit 1
```

`resolve-codex.py` vælger den nyeste installerede stabile CLI fra absolutte
PATH-mapper, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` og
Codex/ChatGPT-apps i `~/Applications` og `/Applications`. Ved npm-installationer
undersøges også pakkens native binær, så en begrænset app/launchd-PATH uden
`node` ikke tvinger et forkert CLI-valg. Versionen skal opfylde
`codex.min_cli_version` i modelregistret. Grænsen er den lokalt verificerede
version, ikke en påstået officiel minimumsversion. Helperen kører kun
`--version`; kontoens modeladgang afgøres stadig ved reviewet.

Brug altid den returnerede absolutte `CODEX_BIN`, aldrig blot `codex exec`
eller en husket sti. Hvis ingen installeret CLI består kontrollen, skal en
[vedvarende CLI-opdatering](references/troubleshooting.md#for-gammel-codex-cli)
løse det; brug ikke en midlertidig npm-installation som standard-workaround.
Et eksplicit valg kan sættes med `PEERREVIEW_CODEX_BIN=/absolut/sti/codex`;
hvis det valg ikke består kontrollen, stopper preflight uden fallback.
Kør ikke nogen reviewer, før preflight lykkes.

Stop højlydt, hvis en CLI eller model ikke er tilgængelig. Gæt aldrig en
erstatningsmodel. En manglende familie må enten relaunches eller markeres som
manglende i slutrapporten.

## 3. Opret privat run-mappe

Brug en ikke-forudsigelig, kun-bruger-læsbar mappe. Dette undgår RID-kollisioner
og symlink-angreb mod forudsigelige `/tmp/review_*`-filer.

```bash
umask 077
REVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-peer-review.XXXXXX")"
REVIEW_RUN_ID="$(basename "$REVIEW_DIR")"
export REVIEW_DIR
touch "$REVIEW_DIR/.llm-peer-review-owned"
python3 "$SCRIPTS/snapshot.py" "$PROJECT_ROOT" > "$REVIEW_DIR/snapshot.before.json"
printf 'REVIEW_DIR=%s\nREVIEW_RUN_ID=%s\n' "$REVIEW_DIR" "$REVIEW_RUN_ID"
```

Genbrug aldrig en run-mappe. Gem dens absolutte sti i statusopdateringerne.

## 4. Definér én fælles prompt

Tilpas kun domænelisten, hvis brugeren bad om et specifikt auditfokus. Bevar
scope, outputkontrakt og read-only-instruksen identisk for alle tre stemmer.

```bash
REVIEW_PROMPT='Review every tracked or non-ignored untracked source file under the current project directory (in a non-Git directory, review source files except .git internals) for concrete correctness bugs, race conditions, lock-ordering problems, security issues, non-atomic file operations, crashes, and invariant violations. Ignore style and naming. Do not modify, create, delete, format, stage, or commit files. For every finding use these plain-text labels on separate lines: Severity: (P0-P3), Location: (file:line), Behavior: (faulty behavior), Impact: (concrete consequence), Fix: (concrete correction). One well-supported finding is sufficient. Output findings only. End with CHECKED: followed by the files or areas actually reviewed. If there are no findings, also output NO_FINDINGS.'
```

## 5. Launch de tre stemmer parallelt

Kør hele blokken i én langvarig terminalsession med kort initial yield. Behold
session-id'et og poll den, så brugeren fortsat får status.

### Claude

```bash
CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p \
  --model "$CLAUDE_MODEL" \
  --effort "$CLAUDE_EFFORT" \
  --setting-sources user \
  --tools "Read,Glob,Grep" \
  --disallowedTools "Agent" "Task" \
  --permission-mode dontAsk \
  --system-prompt "You are one standalone code reviewer, not an orchestrator. Read the code yourself. Never launch agents or other reviewers. Never modify files. Return only concrete review findings with file:line evidence." \
  --output-format json \
  "$REVIEW_PROMPT" \
  </dev/null \
  > "$REVIEW_DIR/review_claude_${REVIEW_RUN_ID}.json" \
  2> "$REVIEW_DIR/review_claude_${REVIEW_RUN_ID}.err" &
CLAUDE_PID=$!
```

### Gemini

```bash
GEMINI_REVIEW_MODEL="$GEMINI_MODEL" \
  "$SCRIPTS/gemini-review.sh" \
  "$REVIEW_RUN_ID" "$REVIEW_PROMPT" "$PROJECT_ROOT" &
GEMINI_PID=$!
```

`agy` har intet tool-level read-only flag. Wrapperen prepender read-only-
instruktionen og klassificerer output, men indholdskontrollen er stadig
obligatorisk.

Standardgrænsen er 15 minutter pr. Gemini-forsøg, med højst ét retry.
Sæt `GEMINI_ATTEMPT_CAP` i sekunder for et andet reviewomfang. Watcherens
standardgrænse er 35 minutter, så begge forsøg har tid til at afslutte.
Ved en længere forsøgsgrænse skal `REVIEW_MAX_ITER` også give plads til begge
forsøg plus opstart og oprydning (`REVIEW_POLL_INTERVAL` er normalt 10 sekunder).

Wrapperen gemmer hver rå JSON-envelope og klassificerer kun dens udtrukne
`.response`. Brug aldrig intern AGY-dialog som reviewerens stemme.

### Codex

Pin både model og reasoning fra `models.json`. `--ignore-user-config` fjerner
personlige plugins/MCP-indstillinger, og `project_doc_max_bytes=0` forhindrer
global eller projektlokal `AGENTS.md` i at frame revieweren som orchestrator.

```bash
"$CODEX_BIN" exec \
  --ignore-user-config \
  --model "$CODEX_MODEL" \
  -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
  -c project_doc_max_bytes=0 \
  --sandbox read-only \
  --skip-git-repo-check \
  --cd "$PROJECT_ROOT" \
  --color never \
  --output-last-message "$REVIEW_DIR/review_codex_${REVIEW_RUN_ID}.last.md" \
  "$REVIEW_PROMPT" \
  </dev/null \
  > "$REVIEW_DIR/review_codex_${REVIEW_RUN_ID}.out" \
  2> "$REVIEW_DIR/review_codex_${REVIEW_RUN_ID}.err" &
CODEX_PID=$!
```

## 6. Vent uden at editere

```bash
if "$SCRIPTS/wait-for-reviewers.sh" "$REVIEW_RUN_ID" \
  "$CLAUDE_PID" "$CODEX_PID" "$GEMINI_PID"; then
  WATCH_RC=0
else
  WATCH_RC=$?
fi
printf 'watcher exit=%s\n' "$WATCH_RC"
```

Mens blokken kører: send korte statusopdateringer, men udfør ingen kommandoer,
der kan ændre projektet. Watcher exit `1` betyder mindst én ikke-gyldig stemme;
det betyder ikke nødvendigvis, at de andre output er ubrugelige.

## 7. Kontrollér read-only-invarianten

```bash
python3 "$SCRIPTS/snapshot.py" "$PROJECT_ROOT" > "$REVIEW_DIR/snapshot.after.json"
diff -u "$REVIEW_DIR/snapshot.before.json" "$REVIEW_DIR/snapshot.after.json"
```

Begge snapshot-kald skal lykkes. Exit `0` og tom diff bekræfter samme filindhold, filtilstand og Git-tilstand ved de to målepunkter. Det er efterkontrol, ikke skrivebeskyttelse; en ændring som gendannes under kørslen kan ikke opdages. Manifestet omfatter tracked og ikke-ignorerede untracked filer. Ignorerede filer er uden for reviewets scope. I en mappe uden Git medtages alle filer undtagen `.git`. Placér run-mappen uden for projektroden. Hvis diffen viser ændringer,
stop aggregeringen, identificér årsagen og kør alle tre igen på et stabilt
snapshot.

## 8. Klassificér og ekstrahér

```bash
CF="$REVIEW_DIR/review_claude_${REVIEW_RUN_ID}.json"
GF="$REVIEW_DIR/review_gemini_${REVIEW_RUN_ID}.json"
XF="$REVIEW_DIR/review_codex_${REVIEW_RUN_ID}.last.md"

CEF="$REVIEW_DIR/review_claude_${REVIEW_RUN_ID}.extracted.md"
GEF="$REVIEW_DIR/review_gemini_${REVIEW_RUN_ID}.extracted.md"
XEF="$REVIEW_DIR/review_codex_${REVIEW_RUN_ID}.extracted.md"

"$SCRIPTS/extract-review-output.sh" "$CF" > "$CEF"
"$SCRIPTS/extract-review-output.sh" "$GF" > "$GEF"
"$SCRIPTS/extract-review-output.sh" "$XF" > "$XEF"

for f in "$CEF" "$GEF" "$XEF"; do
  printf '%s => ' "$(basename "$f")"
  "$SCRIPTS/classify-review.sh" "$f"
done

cat "$CEF"
cat "$GEF"
cat "$XEF"
```

Udled aldrig formatet fra filendelsen. Gemini-stemmens historiske `.json`-fil
er publiceret Markdown; helperen afgør formatet fra indholdet og afviser reelle
fejl-envelopes. Brug de tre `*.extracted.md`-filer ved aggregeringen.

Kun `VALID` og `CLEAN` tæller. Ved `MISFIRE`, `CAPACITY`, `REFUSED`, `ERROR`,
`WEAK`, `EMPTY` eller `MISSING`: følg
[references/troubleshooting.md](references/troubleshooting.md), relaunch højst
én gang med en ny privat run-mappe, og markér derefter stemmen som manglende.

## 9. Aggregér uden at opfinde konsensus

Byg tabellen direkte fra de gyldige `*.extracted.md`-outputs:

| # | Finding | Severity | Evidens | Stemmer | Disposition |
|---|---|---|---|---|---|
| 1 | Kort problem | high | `path/file.swift:42` | Claude, Codex | accept |

- To eller tre uafhængige stemmer: konsensusfinding, men verificér stadig linjen.
- Én stemme: læs den citerede kode og bekræft eller afvis med konkret evidens.
- `CLEAN`: gyldig stemme med nul findings, ikke en finding i sig selv.
- Manglende stemme: skriv familie, verdict og årsag øverst; sænk tilliden.
- Sammenlæg semantisk samme issue, selv når linjenumre eller formulering varierer.

Returnér rapporten i svaret. Skriv kun en rapportfil eller ret kode, hvis brugeren
bad om det. Hvis fixes er autoriseret, begynd først efter denne aggregering.

## 10. Ryd run-filer op

Ryd kun den mappe, som dette flow selv oprettede, og først når de nødvendige rå
outputs er ekstraheret eller gemt efter brugerens ønske:

```bash
if [ -f "$REVIEW_DIR/.llm-peer-review-owned" ]; then
  rm -rf -- "$REVIEW_DIR"
else
  echo "Refusing cleanup: ownership marker missing: $REVIEW_DIR" >&2
fi
```
