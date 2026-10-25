# llm-peer-review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** En ny version af triplereview-skill'en, `llm-peer-review`, som skill + Claude Code-plugin: fælles JSON-schema-output fra alle tre voices, diff-scope (`auto` som default), adversarial mode og ét entry-script, der kan køre i baggrunden.

**Architecture:** Kopiér triplereview til dette repo og omdøb den. Bash-blokkene fra SKILL.md §1-§8 flyttes ind i `run-review.sh` (companion-script-idéen fra codex-plugin-cc). To nye Python-helpere, `prepare_review.py` (scope, diff og prompt) og `review_json.py` (extract, validate, classify og aggregate), erstatter den regex-baserede gyldighedsvurdering. Fejlklasserne (CAPACITY/REFUSED/MISFIRE/ERROR) beholdes. Pluginet er et tyndt lag af slash-commands ovenpå skill'en.

**Tech Stack:** Bash (kompatibel med 3.2 på macOS), Python 3 (kun stdlib, `unittest`), `jq`, `git`, CLI'erne `claude` 2.1.309, `codex` 0.164.0 og `agy` 1.4.5.

**Spec:** Der er ingen separat spec. Beslutningerne er truffet i chatten 2026-10-24 og står under Global Constraints. Kilder: `<original triplereview skill>` (originalen), https://github.com/openai/codex-plugin-cc (scope-valg, adversarial-prompt, review-schema, companion-script, result-handling-regler), https://github.com/simplybychris/antigravity-plugin-cc (agy-discovery og auth-check, setup-command, `--sandbox`).

## Global Constraints

- Repo-rod: `<repo>`. Skill-mappe (forkortet `SK` herunder): `plugins/llm-peer-review/skills/llm-peer-review`.
- Originalen i `<original triplereview skill>` må ikke ændres.
- Omdøbning: `triplereview` → `llm-peer-review`, `TRIPLEREVIEW_` → `PEERREVIEW_`, `.triplereview-owned` → `.llm-peer-review-owned`, mktemp-præfiks `llm-peer-review.XXXXXX`.
- Output-format: alle tre voices skal returnere JSON, der matcher `SK/schemas/review-output.schema.json`. Tekstkontrakten (`Severity:`/`Location:`/`CHECKED:`/`NO_FINDINGS`) udgår.
- Scope: `--scope auto|working-tree|branch|full`, default `auto`, plus `--base <ref>`. `auto` vælger working-tree, når arbejdstræet er dirty, ellers branch-diff mod default branch. En mappe uden Git giver `full`.
- Pakning: skill + Claude Code-plugin. Skill'en skal stadig virke selvstændigt i Codex via `SK/agents/openai.yaml`.
- Kun Python-stdlib. Ingen nye afhængigheder. Bash-scripts skal virke i `/bin/bash` 3.2 (ingen `${var,,}`, ingen `mapfile`).
- Modelnavne findes kun i `SK/scripts/models.json`. Ingen andre filer må hardcode et modelnavn.
- SKILL.md, references og commands skrives på dansk. Prompts til reviewerne skrives på engelsk.
- Reviewere er read-only. Read-only-invarianten gælder fortsat: indholdsmanifestet før og efter skal være identisk.
- Rapportfil: `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md` i projektroden. Agent og model er orkestratorens, med små bogstaver, mellemrum erstattet af `_` og punktummer bevaret.
- Efter rapporten: STOP og spørg brugeren, hvilke findings der skal rettes. Ret aldrig automatisk.
- Repo-konvention: `AGENTS.md` er eneste kilde. `CLAUDE.md` indeholder kun `@AGENTS.md` på første linje.
- Tekst afledt af codex-plugin-cc (Apache-2.0) skal krediteres i `NOTICE`.

## Review Focus

1. Projektsti med mellemrum (`/tmp/x/my project`): hele kørslen skal virke. Testes i Task 7.
2. Fokustekst med shell-metategn (`"; touch /tmp/pwn; echo "`): teksten skal nå prompten ordret og aldrig blive eksekveret. Testes i Task 5 og Task 7.
3. Model returnerer JSON i en ```` ```json ````-fence: det skal klassificeres som gyldigt og ikke som WEAK. Testes i Task 3.
4. Samme fund rapporteret som `./src/a.py`, `src/a.py` og `/abs/root/src/a.py`: det skal blive én klynge med flere stemmer. Testes i Task 4.
5. Repo uden `origin/HEAD` og uden `main`/`master`/`trunk`: `auto` på et rent træ skal fejle med en besked, der foreslår `--base` eller `--scope full`, og ikke crashe. Testes i Task 5.

---

### Task 1: Bootstrap repo fra triplereview

**Files:**
- Create (kopi): `SK/SKILL.md`, `SK/agents/openai.yaml`, `SK/references/{hardening,troubleshooting}.md`, `SK/scripts/*` (uden `__pycache__`)
- Create: `AGENTS.md`, `CLAUDE.md`, `.gitignore`
- Udelad: `Gemini-review-output-report-2026-08-04.md`

**Interfaces:**
- Produces: skill-træet under `SK`, hvor alle eksisterende tests er grønne under det nye navn.

- [x] **Step 1: Kopiér og initialisér**

```bash
cd <repo>
git init -b main
SK=plugins/llm-peer-review/skills/llm-peer-review
mkdir -p "$SK"
rsync -a --exclude __pycache__ --exclude 'Gemini-review-output-report-*' \
  <original triplereview skill>/ "$SK/"
printf '__pycache__/\n*.pyc\n' > .gitignore
```

- [x] **Step 2: Omdøb**

Anvend omdøbningen fra Global Constraints med `grep -rl` + `sed -i ''` på alle filer under `SK`. Frontmatter i `SK/SKILL.md` skal have `name: llm-peer-review`.

- [x] **Step 3: Skriv `AGENTS.md` og `CLAUDE.md`**

`AGENTS.md`: formål (én linje), layoutet fra Global Constraints, testkommandoen fra Step 4, reglen "modelnavne kun i models.json" og reglen "originalen i OLD må ikke ændres". `CLAUDE.md`: præcis `@AGENTS.md`.

- [x] **Step 4: Kør alle eksisterende tests**

Run: `cd "$SK/scripts" && for t in test-*.sh; do bash "$t" || exit 1; done && python3 test-resolve-codex.py`
Expected: alle `ok`, exit 0.

Run: `grep -rni triplereview "$SK"`
Expected: ingen output.

- [x] **Step 5: Commit** – `git add -A && git commit -m "chore: bootstrap llm-peer-review from triplereview"`

---

### Task 2: Review-schema + CLI-spike (fastlæg den faktiske adfærd)

Formålet er at måle, hvordan de rigtige CLI'er opfører sig, så de næste tasks bygger på virkelige fixtures og ikke på gæt. Spiket koster et par små live-kald.

**Files:**
- Create: `SK/schemas/review-output.schema.json`
- Create: `SK/scripts/fixtures/{claude-envelope.json,codex-last.json,agy-envelope.json}`
- Modify: `SK/references/hardening.md` (ny sektion "Verificeret CLI-adfærd 2026-10-24")

**Interfaces:**
- Produces: schemaet (felter herunder) og tre rigtige output-fixtures, som Task 3 og Task 7 bruger.

- [x] **Step 1: Skriv schemaet**

Udgangspunkt er `plugins/codex/schemas/review-output.schema.json` fra codex-plugin-cc med én tilføjelse. Top-niveau `required: ["verdict","summary","findings","checked","next_steps"]` og `additionalProperties: false`. `verdict`: enum `approve|needs-attention`. `findings[]` har `severity` (enum `critical|high|medium|low`), `title`, `body`, `file`, `line_start`/`line_end` (integer ≥1), `confidence` (number 0-1) og `recommendation`, alle required med `additionalProperties: false`. Nyt felt: `checked` (array af strings). `next_steps` er en array af strings. Brug ikke `minItems`. Strict structured output kan afvise det, så Task 3 håndhæver det i stedet.

- [x] **Step 2: Lav et throwaway-projekt**

```bash
P="$(mktemp -d /tmp/peer-spike.XXXXXX)"; R="$(mktemp -d /tmp/peer-run.XXXXXX)"
cd "$P" && git init -q && printf 'def avg(xs):\n    return sum(xs) / len(xs)\n' > calc.py && git add . && git commit -qm init
printf 'def avg(xs):\n    return sum(xs) / (len(xs) - 1)\n' > calc.py
git diff HEAD > "$R/target.diff"
```

- [x] **Step 3: Claude med schema og `--add-dir`**

Brug Claude-kommandoen fra `SK/SKILL.md` §5 med `--add-dir "$R"` og `--json-schema "$(cat schema)"`. Prompten er "Read $R/target.diff, review calc.py, return JSON per schema". Gem stdout som `fixtures/claude-envelope.json`.
Expected: `jq '.structured_output.findings | length'` ≥ 1. Notér i hardening.md, om Read af `$R` virkede under `dontAsk`.

- [x] **Step 4: Codex med `--output-schema`**

Brug Codex-kommandoen fra §5 plus `--output-schema schema`. Gem `--output-last-message` som `fixtures/codex-last.json`.
Expected: filen er gyldig JSON med `findings`. Notér, om read-only-sandboxen kunne læse `$R/target.diff`.

- [x] **Step 5: agy med schema samt read-only-probe**

Kør `agy -p … --output-format json --json-schema schema --add-dir "$P" --add-dir "$R" --disable-slash-commands` i tre varianter: (a) som nu, med `--dangerously-skip-permissions`; (b) `--mode plan --sandbox` uden skip-permissions; (c) `--sandbox --dangerously-skip-permissions`. Brug review-prompten for hver variant, og derefter en skriveprobe: "Create the file PROBE.txt containing hi".
Expected: gem envelopen fra (a) som `fixtures/agy-envelope.json`. Notér i hardening.md for hver variant, om reviewet blev færdigt headless, og om `PROBE.txt` opstod. Notér også, om `.response` er rå JSON eller indpakket i en fence.

- [x] **Step 6: Beslutning, skrevet ind i hardening.md**

Regel: den første variant i rækkefølgen b, c, a, som både fuldfører reviewet og *ikke* skaber `PROBE.txt`, bliver standard for Task 6. Hvis ingen variant blokerer skrivning, bruges (a) + `--sandbox`, hvis (c) fuldførte, og ellers (a). Notér også det mindste verificerede Codex-version-floor (`codex --version`).

- [x] **Step 7: Commit** – `git add "$SK/schemas" "$SK/scripts/fixtures" "$SK/references/hardening.md" && git commit -m "feat: review JSON schema and verified CLI fixtures"`

---

### Task 3: `review_json.py` extract/validate/classify + slankere `classify-review.sh`

**Files:**
- Create: `SK/scripts/review_json.py`, `SK/scripts/test-review-json.py`
- Modify: `SK/scripts/classify-review.sh`, `SK/scripts/test-classify-review.sh`
- Delete: `SK/scripts/extract-review-output.sh`, `SK/scripts/test-extract-review-output.sh`

**Interfaces:**
- Consumes: schemaet og fixtures fra Task 2.
- Produces:
  - `class ReviewError(Exception)` med `.kind: str` ∈ `{"error","notjson"}`
  - `load_review(path: str) -> dict`: pakker en Claude-envelope ud (`is_error: true` giver `ReviewError("error")`, ellers `structured_output` som dict eller `result` som streng), en agy-envelope (`status == "SUCCESS"` + `response` som streng, anden status giver `"error"`) eller et direkte JSON-objekt. En streng parses efter strip. Er hele strengen én ```` ``` ````/```` ```json ````-fence, parses indholdet. Alt andet giver `ReviewError("notjson")`.
  - `validate(review: dict) -> list[str]`: fejlbeskeder for typer, required-felter og enums iht. schemaet, plus at `checked` ikke må være tom.
  - `classify(review: dict) -> str`: valideringsfejl giver `"WEAK"`, ≥1 finding giver `"VALID"` uanset verdict, 0 findings + `approve` giver `"CLEAN"`, 0 findings + `needs-attention` giver `"WEAK"`.
  - CLI `review_json.py classify FILE` skriver én klasse og returnerer exitkode VALID/CLEAN=0, WEAK=5, ERROR=6, NOTJSON=8.
  - CLI `review_json.py extract FILE` skriver normaliseret JSON (`indent=2`) med exit 0, ellers stderr + exit 65.
  - `classify-review.sh` beholder signaturen `classify_review <file>` (sourced af `wait-for-reviewers.sh` og `gemini-review.sh`) og samme klasseord og exitkoder.

- [x] **Step 1: Skriv failing tests i `test-review-json.py`** (unittest, samme stil som `test-resolve-codex.py`)

```python
def test_real_fixtures_are_valid(self):
    for name in ("claude-envelope.json", "codex-last.json", "agy-envelope.json"):
        self.assertEqual(rj.classify(rj.load_review(FIX / name)), "VALID")
def test_fenced_json_response(self):          # Review Focus 3
    p = self.write('{"status":"SUCCESS","response":"```json\\n' + CLEAN_JSON_ESCAPED + '\\n```"}')
    self.assertEqual(rj.classify(rj.load_review(p)), "CLEAN")
def test_clean_requires_checked(self):
    self.assertEqual(rj.classify({**CLEAN, "checked": []}), "WEAK")
def test_findings_win_over_approve(self):
    self.assertEqual(rj.classify({**CLEAN, "findings": [FINDING]}), "VALID")
def test_needs_attention_without_findings_is_weak(self):
    self.assertEqual(rj.classify({**CLEAN, "verdict": "needs-attention"}), "WEAK")
def test_bad_severity_is_weak(self):
    self.assertEqual(rj.classify({**CLEAN, "findings": [{**FINDING, "severity": "P1"}]}), "WEAK")
def test_claude_error_envelope(self):
    with self.assertRaises(rj.ReviewError) as e: rj.load_review(self.write('{"is_error":true,"result":"x"}'))
    self.assertEqual(e.exception.kind, "error")
def test_prose_is_notjson(self):
    with self.assertRaises(rj.ReviewError) as e: rj.load_review(self.write("Here are my findings: src/a.py:3 bug"))
    self.assertEqual(e.exception.kind, "notjson")
def test_cli_exit_codes(self):  # classify VALID→0, WEAK→5, notjson→8; extract on notjson → 65
```

`CLEAN` og `FINDING` er modul-konstanter i testfilen og bygges efter schemaet.

- [x] **Step 2: Kør og se testene fejle** – `python3 SK/scripts/test-review-json.py` → `ModuleNotFoundError`/FAIL.

- [x] **Step 3: Implementér `review_json.py`** med signaturerne ovenfor. Ingen `jsonschema`-dependency, så validatoren skrives i hånden. Schemaet indlæses fra `Path(__file__).parent.parent / "schemas/review-output.schema.json"`, så enums ikke dupliker schemaet.

- [x] **Step 4: Omskriv `classify_review` i `classify-review.sh`**

Find `review_json.py` via `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, så det også virker, når filen sources af watcheren. Rækkefølge: MISSING/EMPTY (uændret) → `python3 review_json.py classify "$f"`. Ved VALID/CLEAN/WEAK/ERROR returneres den klasse. Ved NOTJSON fortsætter den eksisterende fejlkæde `err` → `caphard` → `refuse` → `capsoft` → `mis`, og ellers WEAK. Slet `loc`, `top`, `structured`, `nofindings`, `checked`, `ok` og `_checked_count`. Opdatér header-kommentaren med en linje, der forklarer, at gyldighed nu afgøres af JSON-schemaet, og at regexen kun bruges til fejl-bodies.

- [x] **Step 5: Opdatér `test-classify-review.sh`**

Slet text-VALID/CLEAN-fixtures (location-, `CHECKED:`- og `NO_FINDINGS`-cases). Behold capacity, refusal, misfire, error og "capacity-tokens citeret i et gyldigt review". Den sidste skal nu være en JSON-fixture, hvis `body` citerer `RESOURCE_EXHAUSTED`, og forventet VALID. Tilføj: de tre fixtures fra Task 2 forventes VALID/0, prosa med `file:line` forventes WEAK/5, og agy-fejl-body'en, som `gemini-review.sh` skriver (`AGY did not produce…` + `{"is_error":true}`), forventes ERROR/6.

- [x] **Step 6: Slet de erstattede extractors** – `git rm SK/scripts/extract-review-output.sh SK/scripts/test-extract-review-output.sh`. Grep efter `extract-review-output` i `SK` skal kun give de steder i SKILL.md/references, som Task 8 omskriver.

- [x] **Step 7: Kør tests** – `python3 SK/scripts/test-review-json.py && bash SK/scripts/test-classify-review.sh && bash SK/scripts/test-gemini-review.sh`
Expected: alt grønt. `test-gemini-review.sh`'s fake agy returnerer tekst-CLEAN, så dens fixtures skal opdateres til JSON i samme step.

- [x] **Step 8: Commit** – `git commit -am "feat: schema-based review classification"` (inklusive den nye fil via `git add`).

---

### Task 4: `review_json.py aggregate` – deterministiske kandidatklynger

**Files:**
- Modify: `SK/scripts/review_json.py`, `SK/scripts/test-review-json.py`

**Interfaces:**
- Consumes: `load_review`, `classify` fra Task 3.
- Produces:
  - `normalize_path(path: str, root: str) -> str`: fjerner `root + "/"`-præfiks og `./`, og bruger POSIX-separator.
  - `cluster(reviews: dict[str, dict], root: str) -> list[dict]`. Hver klynge har `{"file","line_start","line_end","severity","voices": list[str],"confidence": float,"titles": list[str]}`. To findings fra hvilken som helst voice deler klynge, når normaliseret fil er ens, og linjeintervallerne overlapper efter udvidelse med 3 linjer til hver side. Klyngen tager max severity, max confidence og sorterede unikke voices. Sorteringen er severity-rang (critical > high > medium > low) faldende, så antal voices faldende, så fil og så `line_start`.
  - CLI `review_json.py aggregate --root ROOT VOICE=FILE [VOICE=FILE...]` skriver Markdown: først en linje pr. voice med dens klasse (filer der ikke er VALID/CLEAN markeres `MANGLER (<klasse>)`), derefter tabellen `| # | Severity | Location | Voices | Conf | Titles |` med `Location` = `file:line_start-line_end`. Exit 0.

- [x] **Step 1: Failing tests**

```python
def test_path_variants_merge(self):           # Review Focus 4
    r = {"claude": rev(f("./src/a.py", 10)), "codex": rev(f("src/a.py", 12)), "gemini": rev(f("/R/src/a.py", 14))}
    [c] = rj.cluster(r, "/R"); self.assertEqual(c["voices"], ["claude", "codex", "gemini"])
def test_far_lines_do_not_merge(self):
    self.assertEqual(len(rj.cluster({"claude": rev(f("a.py", 10)), "codex": rev(f("a.py", 40))}, "/R")), 2)
def test_sort_severity_then_votes(self):
    # high/1 voice before medium/3 voices; among two highs the 2-voice cluster comes first
def test_aggregate_marks_missing_voice(self):
    # gemini=file with prose → output contains "gemini: MANGLER (WEAK)"
```

`f(file, line, severity="high")` bygger et finding, og `rev(*findings)` bygger et gyldigt review.

- [x] **Step 2: Kør og se FAIL.** – `python3 SK/scripts/test-review-json.py`
- [x] **Step 3: Implementér** `normalize_path`, `cluster` og `aggregate`-CLI'en. Klyngedannelse: sortér alle findings efter (fil, `line_start`) og flet et finding ind i den forrige klynge, hvis de overlapper. Klyngens interval udvides løbende.
- [x] **Step 4: Kør og se PASS.**
- [x] **Step 5: Commit** – `git commit -am "feat: deterministic finding clusters across voices"`

---

### Task 5: `prepare_review.py` – scope, diff og prompts

**Files:**
- Create: `SK/scripts/prepare_review.py`, `SK/scripts/test-prepare-review.py`
- Create: `SK/prompts/review.md`, `SK/prompts/adversarial-review.md`

**Interfaces:**
- Produces:
  - `default_branch(root: str) -> str`: `git symbolic-ref --short refs/remotes/origin/HEAD` uden `origin/`-præfikset, ellers den første af `main`, `master`, `trunk`, der findes lokalt eller som `origin/<navn>`. Ellers `ValueError("Kan ikke finde default branch; brug --base <ref> eller --scope full")`.
  - `resolve_target(root: str, scope: str, base: str | None) -> dict` med `{"mode": "working-tree"|"branch"|"full", "label": str, "base_ref": str|None}`. Regler som codex-plugin-cc `resolveReviewTarget`: `--base` giver branch, `auto` på et dirty træ giver working-tree, `auto` på et rent træ giver branch mod `default_branch`. Er der ingen git-repo, giver `auto`/`full` full, og `working-tree`/`branch` giver `ValueError`.
  - `write_diff(root: str, target: dict, path: str) -> list[str]`. For working-tree skrives `git diff HEAD` (uden HEAD bruges `git diff --cached` + `git diff`), efterfulgt af sektionen `# Untracked files (read them directly):` med `git ls-files --others --exclude-standard`. For branch skrives `git diff <base>...HEAD`. Funktionen returnerer de berørte filer (diff `--name-only` + untracked).
  - `render_prompt(template: str, target: dict, files: list[str], diff_path: str | None, focus: str) -> str` erstatter `{{TARGET_LABEL}}`, `{{TARGET_BLOCK}}` og `{{USER_FOCUS}}`. `TARGET_BLOCK` er en ```` ```text ````-fence (så Gemini-refusal-reframe i `gemini-review.sh` bevarer den uændret) med mode, absolut diff-sti og fil-listen. I full-mode indeholder den i stedet scope-sætningen fra det gamle `REVIEW_PROMPT`. Tom focus bliver `No extra focus provided.`
  - CLI `prepare_review.py --root ROOT --out DIR [--scope auto] [--base REF] [--adversarial] [--focus TEXT]` skriver `DIR/target.json`, `DIR/target.diff` (kun i diff-modes) og `DIR/prompt.md` og printer label. Exit 0. Tom scope giver exit 3 med beskeden `Intet at reviewe i <label>; brug --scope full eller --base <ref>`. `ValueError` giver exit 2.

- [x] **Step 1: Skriv de to prompt-templates**

`review.md`: det gamle `REVIEW_PROMPT`s domæneliste og "ignore style/naming", plus `<grounding_rules>` og `<calibration_rules>` fra codex-plugin-cc `prompts/adversarial-review.md` (opfind aldrig filer eller linjer, markér inferens i `body` og sænk confidence, ét stærkt fund er bedre end flere svage). Derefter read-only-linjen, en instruktion om at læse diff-filen og de berørte filer, "Return only JSON matching the provided schema; list every file or area you inspected in `checked`", samt `{{USER_FOCUS}}`.
`adversarial-review.md`: codex-plugin-cc's adversarial-prompt med `<repository_context>{{REVIEW_INPUT}}` udskiftet med `{{TARGET_BLOCK}}` og samme JSON-/`checked`-linje. Ret ordet "Codex" til "an independent reviewer".

- [x] **Step 2: Failing tests** (unittest, temp-git-repos via `subprocess`)

```python
def test_auto_dirty_is_working_tree(self)       # mode == "working-tree", untracked "new.py" in files
def test_auto_clean_feature_branch(self)        # mode == "branch", base_ref == "main"
def test_auto_clean_on_main_exits_3(self)       # CLI rc == 3, stderr contains "--scope full"
def test_explicit_base(self)                    # --base HEAD~1 → base_ref "HEAD~1"
def test_no_default_branch(self)                # Review Focus 5: branch named "dev", no origin → CLI rc 2, stderr contains "--base"
def test_non_git_auto_is_full(self)
def test_non_git_working_tree_is_error(self)    # rc 2
def test_focus_is_verbatim(self)                # Review Focus 2: focus '"; touch /tmp/pwn; echo "$(id)"' appears exactly in prompt.md
def test_no_placeholders_left(self)             # both templates: "{{" not in prompt.md
def test_target_block_is_fenced(self)           # prompt.md contains "```text" and the absolute target.diff path
```

- [x] **Step 3: Kør og se FAIL.** – `python3 SK/scripts/test-prepare-review.py`
- [x] **Step 4: Implementér** `prepare_review.py`. Alle `git`-kald bruger `subprocess.run([...], check=...)` med argumentlister og aldrig `shell=True`.
- [x] **Step 5: Kør og se PASS.**
- [x] **Step 6: Commit** – `git add SK/prompts SK/scripts/prepare_review.py SK/scripts/test-prepare-review.py && git commit -m "feat: review scope selection and prompt templates"`

---

### Task 6: Preflight (agy-discovery og auth) + launch-hardening af Gemini

**Files:**
- Create: `SK/scripts/preflight.sh`, `SK/scripts/test-preflight.sh`
- Modify: `SK/scripts/gemini-review.sh`, `SK/scripts/test-gemini-review.sh`, `SK/scripts/models.json`

**Interfaces:**
- Produces:
  - `preflight.sh agy-path` skriver den absolutte agy-sti fra PATH, ellers den første eksekverbare af `$HOME/.local/bin/agy`, `/opt/antigravity/bin/agy`, `/usr/local/bin/agy`, `/opt/homebrew/bin/agy`. Exit 0, eller exit 127 med installationsvejledningen `curl -fsSL https://antigravity.google/cli/install.sh | bash` på stderr.
  - `preflight.sh check` skriver én linje pr. komponent, `<navn> ok|MISSING <detalje>`, for `claude`, `agy`, agy-auth (`api-key` når `ANTIGRAVITY_API_KEY` er sat, `oauth` når `$HOME/.gemini/antigravity-cli` findes, ellers MISSING), `codex` (via `resolve-codex.py`), `jq`, `python3`, `git` og `models.sh check`. Exit 0 kun når alt er ok, ellers 1.
  - `gemini-review.sh` bruger `"${AGY_BIN:-agy}"` overalt i stedet for bar `agy`, og tilføjer `--json-schema "$SKILL_DIR/../schemas/review-output.schema.json"`, `--disable-slash-commands`, `--add-dir "$REVIEW_DIR"` og read-only-flagene, der blev valgt i Task 2 Step 6.
  - `models.json`: `codex.min_cli_version` sættes til floor'et verificeret i Task 2. `updated` sættes til `2026-10-24`. `_README` omdøbes.

- [x] **Step 1: Failing tests i `test-preflight.sh`** (samme `assert`-stil som `test-classify-review.sh`). Testene bruger en fake `HOME` og `PATH=/usr/bin:/bin`. Når agy kun findes i `$HOME/.local/bin/agy`, skal `agy-path` printe den sti. Uden agy skal exit være 127. Uden `ANTIGRAVITY_API_KEY` og uden `~/.gemini/antigravity-cli` skal `check` vise `agy-auth MISSING` og exit 1.
- [x] **Step 2: Udvid fake agy i `test-gemini-review.sh`**, så den kræver `--json-schema`, `--disable-slash-commands`, `--add-dir $REVIEW_DIR` og de valgte read-only-flag (`grep -Fq` som de eksisterende checks), og sæt `AGY_BIN` til fake-stien.
- [x] **Step 3: Kør og se FAIL** – `bash SK/scripts/test-preflight.sh; bash SK/scripts/test-gemini-review.sh`.
- [x] **Step 4: Implementér** `preflight.sh` og ændringerne i `gemini-review.sh`. `NEUTRAL_INSTRUCTION` og `SYS_DEFENSIVE` får sætningen `Return only JSON matching the provided schema.`, og `Output findings only.` slettes. Hvis Task 2 valgte en variant uden `--dangerously-skip-permissions`, opdateres header-kommentaren "HARDENING DELTA".
- [x] **Step 5: Kør og se PASS** – begge tests + `python3 SK/scripts/test-resolve-codex.py`.
- [x] **Step 6: Commit** – `git commit -am "feat: preflight with agy discovery/auth and schema-enforced Gemini voice"` (plus nye filer).

---

### Task 7: `run-review.sh` – ét entry-point (flyttet fra SKILL.md §1-§8)

**Files:**
- Create: `SK/scripts/run-review.sh`, `SK/scripts/test-run-review.sh`
- Delete: `SK/scripts/guard-review-model.sh` (modellen indtastes ikke længere af en LLM, da scriptet resolver den selv)

**Interfaces:**
- Consumes: `models.sh`, `resolve-codex.py`, `preflight.sh agy-path`, `snapshot.py`, `prepare_review.py`, `gemini-review.sh`, `wait-for-reviewers.sh`, `review_json.py extract|classify|aggregate`.
- Produces: `run-review.sh [--root DIR] [--scope S] [--base REF] [--adversarial] [--focus TEXT] [--voices claude,gemini,codex]`
  - Første stdout-linje er `REVIEW_DIR=<sti>`.
  - Run-mappen indeholder ved slut `snapshot.{before,after}.json`, `target.json`, `prompt.md`, `review_<voice>_<RID>.*` (de navne `wait-for-reviewers.sh` forventer), `review_<voice>_<RID>.extracted.json`, `verdicts.txt` (`<voice> <KLASSE>` pr. linje) og `aggregate.md`.
  - Exitkoder: 0 = alle valgte voices VALID/CLEAN; 1 = mindst én voice mangler, men aggregate.md er skrevet; 2 = preflight- eller wiring-fejl; 3 = intet at reviewe (videregivet fra prepare); 4 = snapshot ændret, hvor aggregate ikke skrives.

- [x] **Step 1: Failing test `test-run-review.sh`**

Testen bruger fake `claude`, `codex` og `agy` i en temp-bin. Fake `claude` printer `fixtures/claude-envelope.json`. Fake `codex` svarer på `--version` med `codex-cli <floor>`, kopierer `fixtures/codex-last.json` til argumentet efter `--output-last-message` og afviser med exit 97, hvis `--output-schema` mangler. Fake `agy` svarer på `models` med Gemini-ID'et fra `models.sh gemini` og ellers med `fixtures/agy-envelope.json`. `PEERREVIEW_CODEX_BIN` sættes til fake codex, og `HOME` får en fake `.gemini/antigravity-cli`. Projektet er et temp-git-repo i en mappe **med mellemrum** (`"$T/my project"`, Review Focus 1) med en dirty ændring. Cases:
  1. Normal kørsel: exit 0, `verdicts.txt` har tre `VALID`, og `aggregate.md` indeholder `| 1 |`.
  2. `--focus '"; touch '"$T"'/pwn; echo "'`: exit 0, `"$T/pwn"` findes ikke, og `prompt.md` indeholder fokusteksten ordret (Review Focus 2).
  3. Fake agy, der skriver `PROBE.txt` i projektet: exit 4, ingen `aggregate.md`.
  4. Fake claude, der printer `{"is_error":true}`: exit 1, `verdicts.txt` har `claude ERROR`, og `aggregate.md` indeholder `MANGLER`.
  5. `--voices codex`: kun codex er startet (claude/agy-fakes logger kald til en fil, som skal være tom), exit 0.
  6. Rent træ på `main`: exit 3.

- [x] **Step 2: Kør og se FAIL.** – `bash SK/scripts/test-run-review.sh`

- [x] **Step 3: Implementér `run-review.sh`**

Flyt kommandoerne fra den nuværende `SK/SKILL.md` §1-§8 uændret i substansen: `umask 077`, `mktemp -d`, ejermarkør, snapshot før og efter, launch-flagene for Claude og Codex og watcher-kaldet. Ændringer:
- Prompten læses med `"$(cat "$REVIEW_DIR/prompt.md")"`.
- Claude får `--add-dir "$REVIEW_DIR" --json-schema "$(cat "$SCHEMA")"`.
- Codex får `--output-schema "$SCHEMA"`.
- Gemini får `AGY_BIN` og `REVIEW_DIR` som env.
- Fravalgte voices får PID `0`, så watcheren springer dem over.
- Al quoting omkring `$PROJECT_ROOT` skal tåle mellemrum.
- Fejl i preflight giver exit 2, før nogen voice startes.
- Snapshot-diff ≠ tom giver besked + exit 4.

- [x] **Step 4: Kør og se PASS**, og kør derefter hele suiten (`for t in SK/scripts/test-*.sh; …` + `python3` på de tre `test-*.py`).
- [x] **Step 5: Commit** – `git add -A && git commit -m "feat: run-review.sh single entry point; drop model guard hook"`

---

### Task 8: Omskriv SKILL.md, references og openai.yaml

**Files:**
- Modify: `SK/SKILL.md`, `SK/references/hardening.md`, `SK/references/troubleshooting.md`, `SK/agents/openai.yaml`

**Interfaces:**
- Consumes: CLI'en og exitkoderne for `run-review.sh` fra Task 7 og `review_json.py aggregate` fra Task 4.

- [x] **Step 1: Skriv SKILL.md** (dansk, så kort som muligt). Frontmatter-`description` skal nævne triple/tre-LLM review, diff- eller branch-review, adversarial review og pre-merge audit. Sektioner:
  1. *Ufravigelige regler*: de gamle regler 1-6. Regel 3 ændres til "kun schema-gyldige VALID/CLEAN tæller". Ny regel: efter rapporten STOP og spørg.
  2. *Vælg scope og mode*: map brugerens ønske til flags (`--scope`, `--base`, `--adversarial`, `--focus`). Default er `auto`. Fokustekst sendes som ét quoted argument.
  3. *Kør*: i Claude Code bruges `Bash` med `run_in_background: true` og `timeout: 2400000`, hvorefter brugeren får besked om, at reviewet kører. I Codex køres i forgrunden med lang yield. Exitkode-tabellen kommer fra Task 7.
  4. *Ved manglende voice*: relaunch højst én gang med `--voices <voice>` (ny run-mappe). Kræv tom `diff -u old/snapshot.before.json new/snapshot.before.json`, og aggregér derefter på tværs: `review_json.py aggregate --root "$PROJECT_ROOT" claude=<ny> gemini=<gammel> codex=<gammel>`.
  5. *Verificér*: hver klynge i `aggregate.md` læses i kildekoden. Klynger med én stemme skal bekræftes eller afvises med evidens. Semantisk ens klynger flettes.
  6. *Rapportér*: skriv `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md` i projektroden (findings efter severity, `file:line` ordret, inferens bevaret, manglende voices øverst). Gentag i svaret, og spørg derefter (AskUserQuestion i Claude Code), hvilke findings der skal rettes.
  7. *Ryd op*: den gamle §10 med den nye ejermarkør.
- [x] **Step 2: Opdatér references.** `hardening.md`: launch-flagene flyttes til "se `run-review.sh`". Behold rationalet, og tilføj schema-, `--add-dir`- og agy-flag-afsnittene fra Task 2. `troubleshooting.md`: verdict-tabellen, hvor `WEAK` nu betyder "ikke schema-gyldigt JSON" og `CLEAN` betyder "`approve` + 0 findings + ikke-tom `checked`". Fjern punkterne om `NO_FINDINGS`, multiline-`CHECKED:` og `.json`-suffix-markdown. `TRIPLEREVIEW_CODEX_BIN` bliver til `PEERREVIEW_CODEX_BIN`.
- [x] **Step 3: `openai.yaml`**: `display_name: "LLM Peer Review"`, `default_prompt` bruger `$llm-peer-review`.
- [x] **Step 4: Verificér** – `grep -rn -E 'extract-review-output|guard-review-model|NO_FINDINGS|CHECKED:' SK` → ingen output. `grep -rn -E 'claude-opus|gemini-[0-9]|gpt-[0-9]' SK --include='*.md'` → ingen hardcodede modeller.
- [x] **Step 5: Commit** – `git commit -am "docs: rewrite skill for run-review.sh, JSON verdicts and scopes"`

---

### Task 9: Claude Code-plugin + README/NOTICE

**Files:**
- Create: `.claude-plugin/marketplace.json`, `plugins/llm-peer-review/.claude-plugin/plugin.json`
- Create: `plugins/llm-peer-review/commands/{review,adversarial-review,setup}.md`
- Create: `README.md`, `NOTICE`

**Interfaces:**
- Consumes: `run-review.sh` fra Task 7, `preflight.sh check` fra Task 6 og SKILL.md fra Task 8.

- [x] **Step 1: Manifester.** Følg formatet i codex-plugin-cc: marketplace-`name: "kastruppro-peer-review"`, ét plugin `llm-peer-review` med `source: "./plugins/llm-peer-review"`, `version: "1.0.0"` og `author.name: "Tobias Jul Kastrup"`. `plugin.json` har samme name, version, description og author.
- [x] **Step 2: Commands** (frontmatter: `description`, `argument-hint`, `disable-model-invocation: true`, `allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion`):
  - `review.md`, argument-hint `[--scope auto|working-tree|branch|full] [--base <ref>] [focus ...]`. Body: "Følg skill'en i `${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/SKILL.md` med disse argumenter: `$ARGUMENTS`. Fokustekst efter flagene sendes som ét `--focus`-argument og må aldrig splices ind i kommandoen." Tilføj review-only-reglen fra codex-plugin-cc `commands/review.md`.
  - `adversarial-review.md`: som `review.md` plus `--adversarial` og codex-pluginets framing-sætning ("udfordrer valgt implementering, design og antagelser").
  - `setup.md`: kør `bash "${CLAUDE_PLUGIN_ROOT}/skills/llm-peer-review/scripts/preflight.sh" check` og videregiv outputtet. Ved `MISSING` foreslås installation (agy: officiel installer, codex: `npm install -g @openai/codex`, auth: kør CLI'en interaktivt én gang). Installér kun efter AskUserQuestion-bekræftelse.
- [x] **Step 3: README + NOTICE.** README: hvad det er, installation (`/plugin marketplace add <repo>`, `/plugin install llm-peer-review@kastruppro-peer-review`, `/reload-plugins`, `/llm-peer-review:setup`), brug af de tre commands, Codex-brug (peg på `SK`), samt "Inspireret af" med links til de to repos. NOTICE: "Portions of prompts/adversarial-review.md, prompts/review.md (grounding/calibration rules) and schemas/review-output.schema.json are derived from openai/codex-plugin-cc, Copyright 2026 OpenAI, licensed under the Apache License 2.0."
- [x] **Step 4: Validér** – `claude plugin validate plugins/llm-peer-review && claude plugin validate .`
Expected: validering bestået. Findes subcommand'en ikke, kør i stedet `jq -e . .claude-plugin/marketplace.json plugins/llm-peer-review/.claude-plugin/plugin.json` og notér det i commit-beskeden.
- [x] **Step 5: Commit** – `git add -A && git commit -m "feat: Claude Code plugin with review, adversarial-review and setup commands"`

---

### Task 10: Live acceptance

**Files:** ingen kodeændringer, medmindre et fund kræver det (så fix + test i den task, der ejer koden).

- [x] **Step 1: Diff-review på spike-projektet** fra Task 2: `bash SK/scripts/run-review.sh --root "$P"`.
Expected: exit 0, tre `VALID`, og `aggregate.md` har en klynge på `calc.py:2` med 2-3 voices.
- [x] **Step 2: Adversarial full-review af dette repo**: `bash SK/scripts/run-review.sh --root . --scope full --adversarial`.
Expected: exit 0 eller 1. Ved 1 noteres den manglende voice og årsagen fra `.err`.
- [x] **Step 3 (erstattet af `claude plugin validate plugins/llm-peer-review` og `claude plugin validate .`; den interaktive `/plugin install` er overladt til brugeren): Plugin-røgtest i Claude Code**: installér via README-kommandoerne, og kør `/llm-peer-review:setup` og `/llm-peer-review:review` på spike-projektet.
Expected: reviewet kører i baggrunden, der kommer en notifikation, og `CODE_REVIEW_2026-10-24_claude_<model>.md` skrives i spike-projektets rod. Derefter kommer et AskUserQuestion om, hvilke fund der skal rettes.
- [x] **Step 4: Bekræft at originalen er urørt** – `ls -la <original triplereview skill>` → mtimes uændrede (SKILL.md: Oct 9 12:19).
- [x] **Step 5: Commit** eventuelle rettelser.

---

## Bevidst udeladt (fra kilde-repoerne)

Codex-pluginets broker/app-server, `/status`, `/result`, `/cancel`, `/rescue`, `/transfer` og stop-review-gate-hooket. Claude Code-baggrundsopgaver og -notifikationer dækker status. Antigravity-pluginets `settings.json`-patching for model er unødvendig, fordi `agy` 1.4.5 har `--model`. `/ask`, `/delegate`, `/image` og `/research` er ikke reviews. Desuden: inline-diff vs. self-collect (vi skriver altid `target.diff` og giver adgang via `--add-dir`), Gemini `--effort` (model-ID'et pinner allerede tier) og spørgsmålet "wait vs background" (altid background i Claude Code).

## Opfølgning

Status 2026-10-24: alle 10 tasks er leveret. Den afsluttende review (`CODE_REVIEW_2026-10-24_claude_opus_5.5.md`) gav 1 Critical og 7 Important fund. De er rettet sammen med Minor-fundene #10-#18 i `fix(security)`, `fix(prepare)`, `fix(aggregate)` og den efterfølgende docs/test-commit. Hele suiten er grøn, og ingen testprocesser lækker. Stadig åbent:

- [x] #9: relative `PATH`-indgange kan levere `claude`/`git`/`jq` fra projektet. Rettet 2026-10-25: `run-review.sh` beholder kun absolutte indgange (test i test-run-review.sh).
- [ ] Claude-stemmen: `--safe-mode`/`--restricted` er ikke evalueret med et live-kald. Brugerens plugins og hooks indlæses stadig.
- [ ] NOTICE krediterer Apache-2.0-tekst fra codex-plugin-cc, men en kopi af licensen mangler (Apache §4(a)).
- [ ] Plugin-directory-profilen vil have en LICENSE og et ikon. Brugeren har besluttet: ingen LICENSE indtil videre.
- [ ] agy variant d (`--mode plan --sandbox`) er målt én gang (n=1). Genmål den efter hver agy-opgradering.
- [ ] Den interaktive installation (`/plugin marketplace add kastruppro/llm-peer-review`, `/plugin install …`) er ikke testet live. Repoet er nu på GitHub (privat), så det kan testes.
- [x] `snapshot.py` hasher `refs/**`, så `git fetch` under et review giver en falsk exit `4`. Rettet 2026-10-25: kun `refs/heads`/`refs/tags` og de lokale linjer i `packed-refs` (test i test-snapshot.py).
- [x] Brede fund (>40 linjer) fra flere stemmer flettes aldrig automatisk, så antallet af stemmer kan blive for lavt. Rettet 2026-10-25: to brede fund fra forskellige stemmer flettes, når start og slut ligger inden for ±3 (test i test-review-json.py).
