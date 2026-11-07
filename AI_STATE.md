# Project state
_Updated: 2026-11-07_

## Done
- `/toolkit:dream` tasks 1 to 5 and 7 (plan in `tasks/`).

## Current state
Plugin `toolkit`: 5 commands, 3 skills, 1 script (`dream-digest.mjs`: redacted digest, `--record`, `--cleanup`). Tests: `node --test` and `tests/review-guard.tests.ps1`.

## Next steps
1. Task 6: after `bootstrap.ps1 -Apply` and a restart, check `dream?` in the status line, dry run `/toolkit:dream`, reject all once, accept one; tick Checkpoints 3 and 4.
2. Decide whether `bootstrap.ps1` creates the `~/.claude/rules/` folder and reports legacy `:*` permission rules left from older setups.
3. Installs made before the repo rename: on "Marketplace 'workshop' not found", re-add the marketplace with `claude plugin marketplace add`, then re-run `bootstrap.ps1 -Apply`.

## Open issues
- Bash deny rules match prefixes only; documented.
- The transcript format is undocumented.
- The status line ignores `CLAUDE_CONFIG_DIR`.
- The digest counts any non-zero Bash exit as a tool error.

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
