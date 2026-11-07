# Project state
_Updated: 2026-11-07_

## Done
- `/toolkit:dream` tasks 1 to 5 and 7 (plan in `tasks/`). Task 6 dry run: the status line segment and the closing steps work; the run found no recurring pattern, so accepting a proposal is not tested yet.
- Hygiene batch: `save-state` checks the tracking-files rule; `bootstrap.ps1` warns about Bash rules with `:*` before their end (they never match) and about user skills named like a kit skill; the upstream check compares against the common commit, so local commits in the kit clone are no longer held for review; `bootstrap.ps1`, the status line and the dream script all use `CLAUDE_CONFIG_DIR` when it is set.
- Researcher (spec `docs/specs/SPEC-researcher.md`, plan `tasks/plan-researcher.md`): Tasks 1 and 2 done. The `toolkit:researcher` agent (Haiku, `WebSearch` and `WebFetch` only, sourced findings) ships in the plugin; auto-sync holds `plugins/*/agents/` for review; `opusplan` is the kit default model.

## Current state
Plugin `toolkit`: 5 commands, 3 skills, 1 agent (`researcher`), 1 script (`dream-digest.mjs`: redacted digest, `--record`, `--cleanup`). Tests: `node --test`, `tests/review-guard.tests.ps1` and `tests/bootstrap-checks.tests.ps1`.

## Next steps
1. Researcher Checkpoint 1: after `bootstrap.ps1 -Apply` and a restart, `/agents` lists `toolkit:researcher` on `haiku` with only `WebSearch` and `WebFetch`. Then Task 3 (delegation rule through `/toolkit:add-rule`, README) and Task 4 (evaluation on 3 questions).
2. Dream Task 6: once real sessions show a recurring pattern, run `/toolkit:dream` and accept one proposal; then tick Checkpoints 3 and 4.
3. Later: digest ignores "no match" exits; `bootstrap.ps1` creates or reports `~/.claude/rules/`; CI; a Node bootstrap for every OS.
4. Pre-rename installs: on "Marketplace 'workshop' not found", run `claude plugin marketplace add` again, then `bootstrap.ps1 -Apply`.

## Open issues
- Bash deny rules match prefixes only; documented.
- The transcript format is undocumented.
- The digest counts any non-zero Bash exit as a tool error, and counted the `--record` output as an error of an unknown tool.
- `bootstrap.ps1` creates the config folder even in preview mode.

## Decisions
- 2026-10-27 Plugin name `toolkit` — `claude-` prefix is reserved for Anthropic; keeps the "kit/toolbox" idea.
- 2026-10-27 Distribution by fork — the sync hook executes repo code, so each user must run code from a repo they control.
- 2026-10-27 Personal preferences in `~/.claude/rules/` — loaded in every project without prompt and never touched by the kit.
- 2026-10-27 MIT license under the GitHub handle `Jeremie-pires` — permissive, compatible with bundled MIT skills.
- 2026-10-27 No `version` in `plugin.json` — the plugin tracks commits, no bump needed.
- 2026-10-27 Keep `~/.claude-kit` path and `claude-kit-sync.json` names — avoids migrating files on existing machines.
- 2026-10-27 Third-party plugins stay unpinned — their security is their maintainers' responsibility; the README tells users to re-check them.
- 2026-10-27 Auto-sync never fast-forwards changes to `bootstrap.ps1`, `global/settings.base.json`, `global/statusline.js`, plugin hooks or (since 2026-11-01) any script under `plugins/` — they run code; the user reviews them and runs `-Apply` by hand.
- 2026-10-27 Pre-kit backup covers only the files the kit writes — a full copy of `~/.claude` would duplicate credentials and history.
- 2026-10-27 Mods postponed — the API is early access; a Bash guard mod adds little over the documented prefix rules for now.
- 2026-11-01 Dream is per project, on demand, one agent — no always-on agent and no subagents keeps it cheap on a Pro plan; each project keeps its own rules and state.
- 2026-11-01 A local script does every deterministic dream step (digest, redaction, record, cleanup) — zero tokens, and the model never edits JSON or deletes files by hand.
- 2026-11-01 Dream never applies global rules — patterns valid for every project are flagged and go through `/toolkit:add-rule`.
- 2026-11-01 Reminder in the status line, not a hook — free, visible, and never injects text into the session.
- 2026-11-01 Tests at the repo root with `node:test` and synthetic fixtures — nothing test-related ships in the plugin, and no real transcript is committed.
- 2026-11-07 The `:*` check flags only a mid-pattern `:*` — the docs say a trailing `:*` equals a trailing ` *`, so it is not legacy.
- 2026-11-07 With `CLAUDE_CONFIG_DIR` set, bootstrap rewrites the kit's `~/.claude/` paths to that folder — permission rules use the absolute `//<posix path>` form from the docs.
- 2026-11-07 Research is delegated to a Haiku agent with read-only web tools, past 2 searches or pages — keeps fetched pages out of the main context and limits what a hostile page can trigger.
- 2026-11-07 Agent files are held for review by auto-sync — an upstream edit could widen an agent's tools.
- 2026-11-07 `opusplan` is the kit default model — Opus for planning, Sonnet for execution, matching the spec, plan, build workflow.
