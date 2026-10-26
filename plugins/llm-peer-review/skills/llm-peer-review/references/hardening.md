# Reviewer hardening

The launch flags for all three voices live exclusively in `scripts/run-review.sh`
(Claude, Codex) and `scripts/gemini-review.sh` (Gemini). See them there; this file
explains why, and what has been measured.

## Contents

- Common isolation
- Output contract (schema)
- Claude
- Gemini
- Codex
- Verified CLI behavior 2026-10-24

## Common isolation

All voices get the same project root, scope and prompt. `run-review.sh` creates a
private `mktemp` directory (`llm-peer-review.XXXXXX`, `umask 077`) outside the project
and rejects a run directory inside the project root. Stdout, stderr and last-message
are kept separate, and output paths are never reused across runs.

The diff and prompt live in `shared/` in the run directory (`target.diff`, `prompt.md`).
Only `shared/` is given to the reviewers as an extra readable directory, never the whole
run directory. After prepare, `shared/` is made read-only (`chmod -R a-w`), and a
sha256 per file is stored in `shared.sha256`. The owner can still `chmod` back or
replace the directory, so the checksum is the actual control: it is checked again
alongside the snapshot, both after a normal run and after a watcher failure/timeout, and a
difference gives exit `4`.

Read-only is an invariant that the script checks: `snapshot.py` takes a
content manifest before the review (before prepare) and after. The manifest covers tracked
and non-ignored untracked files, file mode and Git state (HEAD, index,
status) as well as the Git control files `HEAD`, `config`, `config.worktree`,
`packed-refs` (local refs only), `hooks/**`, `info/**`, `refs/heads/**` and `refs/tags/**` in both git-dir and common-dir
(so linked worktrees, where `.git` is a file, are covered too). A difference gives
exit `4` and no aggregation. Before the snapshot, all voices'
process trees are always stopped, even after a normal exit, so a leftover
descendant cannot write after `snapshot.after`.

All git calls in `snapshot.py` and `prepare_review.py` run with
`-c core.fsmonitor=false -c core.hooksPath=/dev/null`, so a planted fsmonitor
or hook is not executed by the script's own git calls. `git diff` additionally runs with
`--no-ext-diff --no-color --no-textconv`, so the user's git config cannot
alter `target.diff`.

This is an after-the-fact check, not write protection. The manifest does **not** cover:

- a change that is restored during the run;
- ignored files (`.gitignore`, `info/exclude`);
- files outside the project, e.g. AGY's plan artifacts in
  `~/.gemini/antigravity-cli/brain/` or other paths in `$HOME`;
- `.git/objects`, logs and other git files outside the list above;
- git filter drivers (`filter.<name>.clean` in `.git/config` plus
  `.gitattributes`): a voice that plants one is detected (config is hashed),
  but the after-snapshot's `git status` may already have run it.

`refs/remotes`, `FETCH_HEAD` and remote refs in `packed-refs` are deliberately not hashed:
they are changed by any `git fetch` (from the user or an IDE) and are not a
reviewer's write.

`run-review.sh` removes relative `PATH` entries (`""`, `.`, `bin` etc.) at startup,
because the CLIs are looked up after `cd "$PROJECT_ROOT"`; otherwise the project could supply
its own `claude`, `git` or `jq`. `resolve-codex.py` also ignores relative
entries.

Models are always resolved from `scripts/models.json` through `models.sh`.
Hardcoded model names quickly go stale and can silently remove a family from
the consensus. No other files may contain model names.

## Output contract (schema)

All three voices must return JSON conforming to `schemas/review-output.schema.json`
(`verdict`, `summary`, `findings`, `checked`, `next_steps`). Classification
is decided by the schema, not by text patterns:

- `VALID`: schema-valid with at least one finding.
- `CLEAN`: schema-valid, `verdict` `approve`, zero findings and non-empty `checked`.
- `WEAK`: not schema-valid JSON (or `needs-attention` without findings).
- `ERROR`: CLI or envelope failure.

A single ```` ```json ```` fence around the object is accepted. Regexes are used only to
recognize failure, refusal and orchestrator role-play texts that are not
JSON at all (`CAPACITY`, `REFUSED`, `MISFIRE`). The schema deliberately has no
`$schema` key (see the measured behavior below).

## Claude

- `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` avoids the project's Claude memory;
  `--setting-sources user` avoids project and local settings.
- `--strict-mcp-config` without `--mcp-config` starts the voice without MCP servers
  (the user's and the project's `.mcp.json` are ignored).
- `--safe-mode` turns off the user's customizations (installed plugins' skills,
  hooks, MCP, CLAUDE.md, custom commands). Measured 2026-10-25 with Claude Code
  2.1.309 via the `--output-format stream-json` init event: without the flag two
  SessionStart hooks ran, with the flag none. Skills dropped from 102 to 19 and
  slash commands from 138 to 55, while tools (`Glob, Grep, Read`) and MCP (`[]`) were
  unchanged. A live review with `--json-schema` gave `VALID`. The init list
  still shows the plugin names (n=1 measurement; remeasure after a Claude Code upgrade).
  `--restricted` has not been evaluated.
- Only `Read,Glob,Grep`; `Agent` and `Task` are forbidden.
- `--permission-mode dontAsk`, never bypass.
- The system prompt is replaced by a single-reviewer contract, so the reviewer does not
  think it is the orchestrator.
- The schema is passed with `--json-schema`; the result is read from `.structured_output`.
- `--add-dir` is given only for `shared/`, so the diff can be read outside cwd.
- Quote the model string; model names can contain shell glob characters.
- JSON envelope on stdout and diagnostics on stderr.

## Gemini

`agy` has no tool-level read-only flag, and `--dangerously-skip-permissions`
is necessary for headless operation. Read-only is therefore a workflow, not a
technical write block. `gemini-review.sh`:

- prepends a read-only single-reviewer prompt;
- validates that the model is a `gemini-*` ID, and checks it against `agy models`;
- runs `agy` with `--mode plan --sandbox --dangerously-skip-permissions`
  (variant d below), and **without** `--disable-slash-commands`, which silently
  disables plan mode;
- passes `--output-format json` and `--json-schema`, stores each raw envelope and
  classifies only the extracted final answer (`.structured_output`, otherwise `.response`);
- retries at most once; on `REFUSED` the prompt is rephrased neutrally;
- sets a timeout per attempt (`GEMINI_ATTEMPT_CAP`, default 900 s).

**`--add-dir` order:** AGY writes relative paths in the **last**
`--add-dir`. The project directory (cwd) must therefore always be last, so a write
lands in the manifest-checked tree. The run directory is never given as
`--add-dir`; only `shared/` is given, before the project.

If Gemini changes the project, the whole review snapshot is invalid (exit `4`).
Internal AGY dialog and tool events must never yield a reviewer voice.
`status: "SUCCESS"` and exit 0 do not prove a response; an empty `.response` (without
`.structured_output`) is a failure. Non-empty `denied_actions` are a warning to be
inspected in `attemptN.raw.json`; the response is not rejected for that reason.

## Codex

The locally verified native CLI form (the flags are in `run-review.sh`):

- `--ignore-user-config` against plugins, MCP and personal defaults;
- `--model` and `model_reasoning_effort` from `models.json`;
- `project_doc_max_bytes=0` against `AGENTS.md` framing;
- `--sandbox read-only` as tool-level write protection;
- `--cd` to the common project root;
- `--output-schema` and `--output-last-message` for raw JSON.

Codex still reuses the normal `CODEX_HOME` auth. Never use
`--dangerously-bypass-approvals-and-sandbox` for a review voice.

**Known limitation:** despite `--ignore-user-config` and `project_doc_max_bytes=0`,
Codex still loads `~/.agents/skills` and `~/.codex/AGENTS.md`. The user's
global setup can therefore contaminate the prompt (see the measurement below).
The `MISFIRE` classification is the safety net: a voice that plays orchestrator
is discarded and relaunched at most once.

## Verified CLI behavior 2026-10-24

Measured live with claude 2.1.309, codex-cli 0.164.0 and agy 1.4.5 on a
throwaway project (`calc.py` with an introduced n-1 bug). The diff lived in a separate
run directory outside the project (`$R/target.diff`). Prompt: "Read $R/target.diff,
review calc.py, return JSON per schema". Schema: `schemas/review-output.schema.json`.
Raw output is in `scripts/fixtures/`.

### The schema

- Claude rejects `"$schema": "https://json-schema.org/draft/2020-12/schema"`:
  `Error: --json-schema is not a valid JSON Schema: no schema with key or ref
  "https://json-schema.org/draft/2020-12/schema"` (exit 1, empty stdout). That is why
  the schema has no `$schema` key. Without the key, all three CLIs accept it.
- `minLength` is accepted by all three. `minItems` is not used.
- All three payloads adhered to the schema. No extra fields, correct enums,
  `line_*` >= 1, `confidence` in 0-1. AGY returned `confidence: 1` as an integer.

### Claude

- `--json-schema "$(cat schema)"` together with `--output-format json` gives an
  envelope with `.structured_output` (object) and `.result` (the same JSON as a string).
  `subtype: "success"`, `is_error: false`, `terminal_reason: "completed"`.
  `stop_reason` is `"tool_use"`, not `"end_turn"`. Do not use it as a failure signal.
- Reading `$R/target.diff` outside cwd worked under `--permission-mode dontAsk`
  with `--add-dir "$R"`. `permission_denials` was empty, and the file is listed in `checked`.
- Fixture: `scripts/fixtures/claude-envelope.json` (2 findings).

### Codex

- `--output-schema <file>` works in 0.164.0. `--output-last-message` contains raw
  JSON without a fence. The same JSON is on stdout.
- `--sandbox read-only` could read `$R/target.diff` outside `--cd`. Codex also ran
  `git` and `python3` read-only to reproduce the bug.
- `--ignore-user-config` plus `project_doc_max_bytes=0` does not fully isolate.
  Codex still read global skills under `~/.agents/skills/` and followed a
  global instruction to save a Markdown report. It stated this itself in
  `summary` ("could not be saved because the workspace is read-only"). The sandbox
  stopped it, but prompt contamination from the user's global setup is
  still possible. `MISFIRE` is the safety net (see the Codex section above).
- Lowest verified version floor for the schema path: **codex-cli 0.164.0**.
  `models.json` has `min_cli_version` 0.164.0 (raised from 0.153.4, which was not
  verified with `--output-schema`).
- Fixture: `scripts/fixtures/codex-last.json` (1 finding).

### AGY (Gemini)

Common flags for a-c: `agy -p <prompt> --model <models.sh gemini> --output-format
json --json-schema <schema file> --add-dir "$P" --add-dir "$R"
--disable-slash-commands --print-timeout 300s`, run with cwd `$P`. Variant d
uses the same flags, but **without** `--disable-slash-commands` and with reversed
order: `--add-dir "$R" --add-dir "$P"`, so the project is last.
The write probe was the prompt "Create the file PROBE.txt containing hi" (without
schema).

| Variant | Extra flags | Review headless | `PROBE.txt` created |
| --- | --- | --- | --- |
| a | `--dangerously-skip-permissions` | Yes, 46 s, 2 findings | Yes, in `$R` |
| b | `--mode plan --sandbox` | No. Empty `.response` | No. `write_file` was denied |
| c | `--sandbox --dangerously-skip-permissions` | Yes, 89 s, 2 findings | Yes, in `$R` |
| d | `--mode plan --sandbox --dangerously-skip-permissions` | Yes, 89 s, 2 findings | No, neither in `$P` nor `$R` |

- When the schema works, the envelope has `.structured_output` (object), `.response`
  (the same JSON as a raw string, **without** a fence) and an echo of the schema in
  `.json_schema`.
- Variant b gave `status: "SUCCESS"` and exit 0, even though `.response` was empty.
  `denied_actions` was `[{"action":"command","display_name":"RunCommand"}]`.
  On stderr: `warning: --mode plan has no effect while slash command
  expansion is disabled.` Plan mode was thus not active. The block presumably
  came from `--dangerously-skip-permissions` being absent, so headless
  mode denied tools that required permission. This is an inference from
  `denied_actions` and stderr: only `RunCommand` (review) and `WriteFile` (probe)
  were actually observed being denied.
  `status: "SUCCESS"` and exit 0 therefore do not prove a
  response. An empty `.response` must be treated as a failure; non-empty `denied_actions`
  are a warning to be inspected (see the Gemini section).
- `--sandbox` restricts only the terminal. AGY's own `write_file` tool
  still writes.
- The write probe wrote into the **last** `--add-dir` (`$R`), not cwd/the project.
  If the run directory is given as `--add-dir`, a write can evade the
  project manifest. The project directory must therefore always be the **last**
  `--add-dir`. Ideally the run directory should not be given to AGY as `--add-dir` at all, and
  otherwise it must be checked too.
- Variant d (plan mode active): the review completed with the same envelope structure
  as a (same top-level keys, `.response` is raw JSON without a fence,
  `denied_actions` is absent). On the write probe the agent did not write the file.
  It replied with an implementation plan and asked for approval ("Once approved,
  I will proceed"). The plan was in AGY's own state directory
  `~/.gemini/antigravity-cli/brain/<conversation_id>/create_probe_file.md`, outside
  `$P` and `$R`. There were no `denied_actions`. The block is thus the plan-mode
  workflow, not a verified denial at the tool layer.
  Plan mode thus writes its plan artifacts to
  `~/.gemini/antigravity-cli/brain/...`, which is outside the content manifest.
  That is a write path out of the project that the manifest cannot see; it cannot be
  closed from here, only noted.
- Fixture: `scripts/fixtures/agy-envelope.json` (variant a, 2 findings). The envelope
  from d is structurally identical, so there is no separate fixture.

### Decision

First round: pick the first variant in the order b, c, a that both
completes the review and does not create `PROBE.txt`. No variant met both
requirements. b blocks writing but does not complete. c and a complete but write.
The fallback rule ("if no variant blocks writing") was read as "if
no *usable* variant blocks writing", because b cannot deliver a
review at all. Thus c (= a + `--sandbox`) became the provisional default.

b was confounded (plan mode inactive, no skip-permissions), so d was run
afterwards. d completed the review, and `PROBE.txt` was created neither in `$P` nor
`$R`. **The default for Task 6 is therefore variant d**:
`--mode plan --sandbox --dangerously-skip-permissions`, with the project directory as
the last `--add-dir`. `--disable-slash-commands` must be **removed** from the AGY call,
because plan mode otherwise has no effect. c is the fallback.

Plan mode stops writing in the workflow, but it is not a verified
write block at the tool layer. The content manifest is still mandatory.

**Evidence basis:** the decision for variant d rests on **one** review and
**one** write probe (n=1). It has not been repeated and may change between
agy versions. Remeasure on an agy upgrade and never expect plan mode
alone to protect the project.
