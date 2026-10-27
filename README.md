# llm-peer-review

![License](https://img.shields.io/badge/License-MIT-green)

Three independent LLM reviews of the same code, aggregated into an evidence-based consensus.

The reviewers are Claude (Claude CLI), Gemini (Antigravity CLI `agy`) and Codex (native Codex CLI). They read the same stable, read-only snapshot and return JSON conforming to `schemas/review-output.schema.json`. Only schema-valid responses count as a vote, and findings that several voices point at are grouped into clusters. The repo packages this both as a Claude Code plugin and as a standalone skill that also works in Codex.

After the report, the flow stops and asks which findings to fix. Nothing is fixed automatically.

## Install with `npx skills`

For Codex, Gemini CLI, Cursor, OpenCode and other agents:

```
npx skills add kastruppro/llm-peer-review            # interactive: pick agents
npx skills add kastruppro/llm-peer-review -a codex -a gemini-cli -a claude-code -y
npx skills add kastruppro/llm-peer-review -g -a codex -y   # global (user-level)
```

The skill is self-contained (scripts, prompts, schema, references). The Claude Code plugin below adds the `/llm-peer-review:*` slash commands on top. The requirements are the same either way (see [Requirements](#requirements)): the `claude`, `agy` and `codex` CLIs, `git`, `jq` and `python3`.

## Install (Claude Code plugin)

```
/plugin marketplace add kastruppro/llm-peer-review
/plugin install llm-peer-review@kastruppro-peer-review
/reload-plugins
/llm-peer-review:setup
```

From a local clone you can use the path instead: `/plugin marketplace add /path/to/llm-peer-review`.

`/llm-peer-review:setup` runs preflight and offers to install missing CLIs (after confirmation).

## Usage

| Command | Purpose |
|---|---|
| `/llm-peer-review:review [--scope auto\|working-tree\|branch\|full] [--base <ref>] [focus ...]` | Regular three-LLM review |
| `/llm-peer-review:adversarial-review [same arguments]` | Challenges the chosen implementation, design and assumptions |
| `/llm-peer-review:setup` | Check and install the Claude, `agy` and Codex CLIs |

- `--scope auto` (default) picks `working-tree` when the working tree is dirty, otherwise a branch diff against the default branch. A directory without Git gives `full`.
- If the repo has no `origin/HEAD` and no `main`/`master`/`trunk`, use `--base <ref>` or `--scope full`.
- Text after the flags becomes a single quoted `--focus` argument, never spliced into a shell command.
- The report is written as `CODE_REVIEW_<YYYY-MM-DD>_<agent>_<model>.md` in the project root.

Examples:

```
/llm-peer-review:review
/llm-peer-review:review --scope branch --base main focus on error handling
/llm-peer-review:adversarial-review --scope full
```

## Use in Codex

The skill works standalone without the plugin (the quickest route is `npx skills add`, above). Alternatively, point Codex at the skill directory:

```
plugins/llm-peer-review/skills/llm-peer-review
```

Copy or symlink it into Codex's skills directory and start with `$llm-peer-review` (see `agents/openai.yaml`). The entry point is `scripts/run-review.sh`; the flow and rules are in `SKILL.md`.

## Requirements

`claude`, `agy` (with login or `ANTIGRAVITY_API_KEY`), `codex`, `git`, `jq`, `python3` (stdlib only) and `/bin/bash` 3.2+. Model names live only in `scripts/models.json`.

## Inspired by

- [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc): plugin format, commands, and parts of the review prompts and schema (Apache-2.0, see `NOTICE`).
- [antigravity-plugin-cc](https://github.com/simplybychris/antigravity-plugin-cc): the idea for the `setup` command and the use of `agy`.

## License

MIT (see `LICENSE`). Parts of the prompts and schema come from openai/codex-plugin-cc (Apache-2.0); see `NOTICE` and `LICENSES/Apache-2.0.txt`.
