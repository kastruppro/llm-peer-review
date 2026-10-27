---
name: llm-peer-review
description: >-
  Run three independent, parallel LLM reviews (Claude, Gemini, Codex) of a diff,
  a branch or the whole codebase, validate each response against a JSON schema,
  and aggregate only valid voices into an evidence-based consensus. Use for LLM
  peer review, cross-model code review, triple review, three-LLM review, diff or
  branch review, adversarial review, a thorough pre-merge audit, or an
  independent multi-model review before any fixes are made.
---

# LLM peer review

Three reviewers (Claude CLI, Gemini via Antigravity CLI `agy`, native Codex CLI)
read the same stable snapshot and return JSON conforming to
`schemas/review-output.schema.json`. `scripts/run-review.sh` is the only entry
point: preflight, scope, parallel run, watcher, read-only check, classification
and aggregation. Launch flags and models live only in the scripts and
`scripts/models.json`; never invent your own invocations.

## 1. Inviolable rules

1. Do not change project files, git state or instructions while the reviewers run.
2. Give all voices the same scope and the same core prompt.
3. Only schema-valid `VALID`/`CLEAN` verdicts count as a voice. Silence and errors are not agreement.
4. Verify single-reviewer findings directly in the source code before accepting them.
5. Fix code only after aggregation, and only if the user chooses to (rule 7).
6. The reviewers are read-only. Gemini has only workflow-based read-only, so the
   before/after content manifest (exit `4`) is mandatory.
7. After the report: STOP and ask the user which findings to fix.
   Never fix automatically, even when the fix is obvious.

Do not use the skill for small diffs, lint/style, or a codebase that is being
actively changed. A single reviewer is cheaper there.

## 2. Choose scope and mode

The default is `--scope auto`: a dirty working tree gives `working-tree`,
otherwise a branch diff against the default branch; without Git it becomes `full`.

| The user wants | Flags |
|---|---|
| review of what I changed / plain "review" | none (`auto`) |
| uncommitted changes only | `--scope working-tree` |
| the whole branch / PR against a specific base | `--scope branch --base <ref>` |
| the whole codebase, pre-merge audit | `--scope full` |
| challenge design and assumptions | `--adversarial` |
| steer attention | `--focus "$FOCUS"` (a single argument, see below) |
| only some voices | `--voices claude,codex` |

Focus text is data, never code. Double quotes still expand `$(...)`, backticks
and `$VAR`, so put the text verbatim in a variable via a quoted heredoc and pass
it as a single argument; it is never executed or interpreted:

```bash
FOCUS=$(cat <<'PEER_FOCUS_EOF'
<focus text verbatim>
PEER_FOCUS_EOF
)
# ... --focus "$FOCUS"
```

If the text contains a line identical to the delimiter (`PEER_FOCUS_EOF`), choose
a different, unique delimiter (e.g. with random characters appended) that does
not occur in the text. Never remove or alter the focus text.

`--scope` must be `auto|working-tree|branch|full`, and `--base` a plain ref name
without spaces or shell metacharacters (otherwise ask the user). `--base` can
only be combined with `auto` or `branch`; with `working-tree` or `full` it
gives exit `2`.

If the repo has no `origin/HEAD` and no `main`/`master`/`trunk`, `auto` on a
clean tree fails with a message about `--base` or `--scope full`. Choose one of them.

## 3. Run

`SKILL_DIR` is the absolute directory containing this `SKILL.md`; `PROJECT_ROOT`
is `pwd -P` for the project (paths with spaces are supported, always quote):

```bash
bash "$SKILL_DIR/scripts/run-review.sh" --root "$PROJECT_ROOT" [flags]
```

- **Claude Code:** `Bash` with `run_in_background: true` and `timeout: 2400000`.
  Tell the user the review is running (the watcher limit is 35 min), and do not touch the project.
  Read the result when the background run reports completion.
- **Codex:** run in the foreground with a long yield; send short status messages.

The first stdout line is `REVIEW_DIR=<path>`; later come `TARGET=...`, verdicts and
`AGGREGATE=<path>/aggregate.md`. The script never deletes the run directory.

| Exit | Meaning | Action |
|---|---|---|
| `0` | all selected voices `VALID`/`CLEAN` | go to §5 |
| `1` | at least one voice is missing/invalid; `aggregate.md` exists | §4, then §5 |
| `2` | preflight, wiring, watcher failure or timeout; no aggregation | read stderr, fix the cause ([troubleshooting](references/troubleshooting.md)) |
| `3` | nothing to review (`Nothing to review in <label>; use --scope full or --base <ref>`) | suggest `--scope full` or `--base <ref>` |
| `4` | the project or `shared/` (diff/prompt) changed during the run; no aggregation | find the cause, rerun all voices on a stable snapshot |
| `130`/`143` | interrupted; the voices are stopped | ask the user whether to rerun |

Watcher limits can be tuned with `REVIEW_POLL_INTERVAL`, `REVIEW_MAX_ITER` and
`REVIEW_STALE_ITERS` (see the header of `run-review.sh`).

## 4. When a voice is missing

Read `verdicts.txt` in the run directory and the failure cause in the voice's
`.err` (see [troubleshooting](references/troubleshooting.md)). Relaunch at most
once per voice, with the same scope/`--base`/`--focus`/`--adversarial` and only
the missing voice. This produces a new run directory:

```bash
bash "$SKILL_DIR/scripts/run-review.sh" --root "$PROJECT_ROOT" --voices gemini [same flags]
```

Then require that the project was unchanged between the two runs, and aggregate
across them (`OLD`/`NEW` are the two `REVIEW_DIR`s, `*_RID` are the directories'
basenames):

```bash
diff -u "$OLD/snapshot.before.json" "$NEW/snapshot.before.json" \
  && python3 -I "$SKILL_DIR/scripts/review_json.py" aggregate --root "$PROJECT_ROOT" \
       claude="$OLD/review_claude_$OLD_RID.json" \
       gemini="$NEW/review_gemini_$NEW_RID.json" \
       codex="$OLD/review_codex_$OLD_RID.last.md"
```

A non-empty diff means the runs cannot be mixed: rerun all voices. A voice that
is still not valid after one relaunch is reported as `NOT COUNTED (<class>)` (a
file that does not exist gives `NOT COUNTED (MISSING)`, a schema-invalid response
`NOT COUNTED (WEAK)`). Never substitute the family with a different model.

## 5. Verify

Read each cluster in `aggregate.md` against the source code, not just the
description. `aggregate.md` has titles only. Body, recommendation and the
reviewers' markers of inference and uncertainty are in
`review_<voice>_<RID>.extracted.json` in the run directory (the normalized JSON
response per voice); read them there.

The script groups only by path and proximity: a finding joins a cluster when its
lines are within ±3 lines of the cluster's first finding, never two findings from
the same voice, and a finding over 40 lines is merged only with an equally wide
finding from another voice whose start and end are within ±3. Proximity is not
the same as agreement.

- A cluster with more than one distinct problem must be split; voices count only
  when they describe the same defect.
- Clusters with several voices on the same defect: consensus, but still confirm the location.
- Single-voice clusters: confirm or reject with concrete evidence (code, calls, tests).
- Semantically identical clusters that the script did not merge (different lines/wording) are merged.
- `CLEAN` is a valid zero-finding vote, not a finding.

## 6. Report

Write `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md` in the project root. Agent and
model are the orchestrator's own, in lowercase, spaces replaced by `_` and
version dots kept (e.g. `CODE_REVIEW_2026-10-24_claude_opus_5.5.md`). The file is
a local artifact and must never be committed: never `git add` it. Keep it out of
git with a global ignore (`CODE_REVIEW_*.md` in `~/.config/git/ignore`), not with a
repo `.gitignore`.

- Missing voices at the top: family, last verdict and cause; state that confidence is lower.
- Findings first, sorted by severity (critical, high, medium, low), with
  disposition (accepted/rejected) and evidence.
- `file:line` verbatim as the reviewers reported it, and preserve markers of
  inference, uncertainty and open questions (from `review_<voice>_<RID>.extracted.json`).
  No new findings without a source.
- No findings: say so explicitly and keep residual risk brief.

Repeat the contents in your reply and then STOP. Ask which findings to fix
(AskUserQuestion in Claude Code; otherwise a direct question message).
Touch no files until the user has answered.

## 7. Clean up

The run directory is outside the project. Clean up only the directory this flow
itself created, and only after the report is written (and any raw outputs are
saved as the user wishes):

```bash
if [ -f "$REVIEW_DIR/.llm-peer-review-owned" ]; then
  rm -rf -- "$REVIEW_DIR"
else
  echo "Refusing cleanup: ownership marker missing: $REVIEW_DIR" >&2
fi
```

## Resources

- `scripts/run-review.sh`: entry point, flags, exit codes, run directory layout.
- `scripts/review_json.py`, `scripts/classify-review.sh`: schema validation, verdicts, aggregation.
- `scripts/models.json`: the only place with model names.
- `prompts/review.md`, `prompts/adversarial-review.md`: reviewer prompts (English).
- [references/hardening.md](references/hardening.md): isolation, measured CLI behavior, rationale.
- [references/troubleshooting.md](references/troubleshooting.md): verdicts and failures.
