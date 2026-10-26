# Verdicts and recovery

## Verdicts

Validity is decided by the JSON schema (`review_json.py`), not by text patterns. See
`verdicts.txt` in the run directory for each voice's verdict.

| Verdict | Meaning | Action |
|---|---|---|
| `VALID` | Schema-valid JSON with at least one finding | Counts as a voice |
| `CLEAN` | Schema-valid: `approve`, 0 findings and non-empty `checked` | Counts as a valid zero-finding voice |
| `WEAK` | Not schema-valid JSON (or `needs-attention` without findings, or unrecognizable prose) | Inspect the raw output; relaunch once |
| `ERROR` | CLI or envelope failure (e.g. `is_error`, agy not `SUCCESS`) | Read `.err`, fix the cause and relaunch once |
| `MISFIRE` | Reviewer role-played the orchestrator | Relaunch once (new run directory) |
| `CAPACITY` | Auth, quota, network or model capacity | Check the CLI/auth and relaunch once |
| `REFUSED` | Gemini over-refusal | The wrapper rephrases neutrally once. If the refusal survives that, a relaunch with the same model rarely helps: aggregate as a 2-voice review and note the missing Google voice, or fix `gemini.model` in `models.json` (see its `note`) and relaunch only Gemini with `--voices gemini` (SKILL.md §4) |
| `EMPTY` / `MISSING` | No usable output (under 40 bytes / the file does not exist) | Check the PID, path and stderr |

Only `VALID` and `CLEAN` count. A voice that is still not valid after one
relaunch is marked as not counted (`NOT COUNTED (<class>)` in `aggregate.md`, e.g.
`NOT COUNTED (MISSING)` or `NOT COUNTED (WEAK)`). Its silence must never be used
as agreement. The relaunch recipe is in SKILL.md §4.

## Exit codes from run-review.sh

- **`2`:** preflight (missing CLI, `jq`, `agy` auth, no compatible Codex),
  wrong argument (also `--base` together with `--scope working-tree|full`), run directory inside the project, watcher failure or timeout.
  The voices' processes are stopped, and there is no `aggregate.md`. Read stderr.
- **`3`:** `prepare_review.py` found nothing to review
  (`Nothing to review in <label>; use --scope full or --base <ref>`). Use
  `--scope full` or `--base <ref>`.
- **`4`:** the snapshot diff (the project incl. `.git` control files) or the
  `shared/` checksum is not empty. Find the cause (editor, formatter,
  watcher process, `git commit`/`checkout`, a reviewer that wrote something) and rerun all voices.
  A plain `git fetch` no longer gives exit `4` (remote refs are not hashed).
- **`130`/`143`:** interrupted; the run directory is preserved.

## Common failures

- **`auto` fails on a clean tree:** the repo has neither `origin/HEAD` nor
  `main`/`master`/`trunk`. Pass `--base <ref>` or `--scope full`.
- **Output mixed with stderr:** use separate files; otherwise JSON and classify fail.
- **Wrong model despite success:** models come only from `models.json` via
  `models.sh`; Codex also gets an explicit `--model` and reasoning override.
- **Known model rejected from `agy models`:** some AGY versions show
  `model-id\\tlabel` with a literal `\\t`. The wrapper must extract the leading
  technical `gemini-*` ID and match that exactly, not the whole display line.
- **Reviewer scope varies:** all voices get the same `shared/prompt.md` and
  `shared/target.diff`; do not compare a full tree with diff-only.
- **`AGENTS.md`, `GEMINI.md` or other memory takes over the role (`MISFIRE`):**
  see the isolation sections in [hardening](hardening.md). Codex still loads
  `~/.agents/skills` and `~/.codex/AGENTS.md`; `MISFIRE` is the safety net.
- **Model returns JSON in a ```` ```json ```` fence:** this is valid and is classified
  normally. Only a single fence around the whole object is accepted.
- **`WEAK` on a response that looks like a review:** validate against
  `schemas/review-output.schema.json` (`python3 -I scripts/review_json.py classify <file>`):
  extra fields, a wrong enum, `line_*` below 1 or `confidence` outside 0-1
  give `WEAK`.
- **The same finding appears as several clusters:** `aggregate.md` merges only on
  normalized path and lines within ±3 of the cluster's first finding (never the same
  voice; findings over 40 lines only with an equally wide one with start and end within ±3); merge semantically identical clusters manually (§5).
- **One cluster contains several problems:** split it (SKILL.md §5); voices count only
  when they describe the same defect.
- **Internal AGY dialog gives a false `VALID`:** check `attemptN.raw.json`, but
  classify only `attemptN.final.md`, extracted from the envelope.
- **A retry overwrites evidence:** each attempt keeps `attemptN.raw.json`,
  `attemptN.final.md`, `attemptN.err` and `attemptN.classify.txt`.
- **Empty `.response` from agy despite `SUCCESS`:** treat it as a failure; check
  `denied_actions` and stderr (see [hardening](hardening.md)).
- **The review process is gone but the output is empty:** read the corresponding `.err` and
  check auth/model before relaunching.

## Outdated Codex CLI

Run `python3 -I "$SKILL_DIR/scripts/resolve-codex.py"` in preflight and use the returned
absolute path as `"$CODEX_BIN" exec`. The helper checks PATH, fixed
installation directories, the npm package's native binary and app CLIs with `--version`
(at most five seconds per candidate). It filters out old, unknown and
prerelease versions and changes neither PATH, installations nor models.

If no candidate passes, fix the persistent installation as part of an
authorized CLI update. Avoid repeated one-off installs in `/tmp` and
do not lower the version floor to get an old CLI through. First find the owner
with `ls -l /absolute/path/codex`; update with the same package manager. For the local
npm installation under `/opt/homebrew` the command is:

```bash
/opt/homebrew/bin/npm install --global @openai/codex@latest
CODEX_BIN="$(python3 -I "$SKILL_DIR/scripts/resolve-codex.py")" || exit 1
"$CODEX_BIN" --version
```

This is a separate, persistent update; the resolver never installs
software automatically during a review. Alternatively, an existing,
compatible CLI can be selected with `PEERREVIEW_CODEX_BIN`. Reassess the version floor
at a later model change; the version check does not prove model access on the account.

## Codex auth

If native Codex returns 401, an invalidated token or a sign-in error, use the
local Codex login mechanism and verify auth before rerunning the voice. Do not replace
the OpenAI family with an extra Claude or Gemini model.

## Missing family

If a family cannot deliver after one controlled relaunch, continue only if
the user accepts the reduced coverage or the task allows best effort.
Report clearly:

1. which family is missing;
2. the last verdict and failure cause;
3. that a 2-voice consensus is weaker;
4. which single-reviewer findings therefore require extra manual evidence.
