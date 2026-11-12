# Project state
_Updated: 2026-11-12_

## Done
- Safe sync (spec `docs/specs/SPEC-safe-sync.md`, plan `tasks/plan-safe-sync.md`), Tasks 1 to 7 and Checkpoints 1 and 2:
  - The kit clone is updated with `git rebase --autostash`. A conflicting local commit, or an untracked file in the way, aborts the rebase and leaves the clone as it was. Uncommitted edits that clash on re-apply stay in the stash; the kit then skips clone updates and deployed files until the user follows the warning's recovery steps.
  - `CLAUDE.md` and `statusline.js` are merged three ways (`git merge-file`) against the kit's version from the last sync, stored in `claude-kit-base/`. Conflicts go to `<file>.kit-merge`, never into the deployed file. A merged `statusline.js` must pass `node --check`. Installs from before merge bases find their base in the clone's history by hash, line endings included.
  - Preview fetches but never rebases. `-Apply` creates `~/.claude/rules/`, the documented home for machine-local content.
  - README, script header and troubleshooting rows cover every new warning and the one-time manual update for existing installs.

## Current state
Plugin `toolkit`: 5 commands, 3 skills, 1 agent (`researcher`), 1 script (`dream-digest.mjs`). `bootstrap.ps1` syncs settings, the rules file and the status line without dropping local edits. Tests: `node --test`, `tests/review-guard.tests.ps1`, `tests/bootstrap-checks.tests.ps1` and `tests/safe-sync.tests.ps1` (129 checks, two of them end to end). All pass.

## Next steps
1. Safe sync Checkpoint 3: commit, push, then on each machine run `git -C ~/.claude-kit pull --rebase --autostash` once by hand, resolve any conflict, and run `bootstrap.ps1 -Apply`; check that local edits and untracked files in the clone survive.
2. Researcher Task 4: evaluation on 3 questions.
3. Dream Task 6: once real sessions show a recurring pattern, run `/toolkit:dream` and accept one proposal; then tick Checkpoints 3 and 4.
4. Later: digest ignores "no match" exits; CI; a Node bootstrap for every OS.
5. Pre-rename installs: on "Marketplace 'workshop' not found", run `claude plugin marketplace add` again, then `bootstrap.ps1 -Apply`.

## Open issues
- Bash deny rules match prefixes only; documented.
- The transcript format is undocumented.
- The digest counts any non-zero Bash exit as a tool error, and counted the `--record` output as an error of an unknown tool.
- `bootstrap.ps1` creates the config folder even in preview mode, and preview still runs `git fetch` in the clone.
- `tests/safe-sync.tests.ps1` takes about 5 minutes, mostly in throwaway git repos.

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
- 2026-11-12 Machine-local content lives in `~/.claude/rules/`, kit-deployed files belong to the kit — a file the user owns can never conflict with an update.
- 2026-11-12 The clone is updated with `rebase --autostash` and a conflict is aborted — local commits and edits are carried over, and no half-done rebase is ever left behind.
- 2026-11-12 Deployed files are merged three ways against a stored copy of the kit's last version — a hash alone cannot tell a local edit from an upstream change, and conflict markers never reach a file Claude Code loads.
- 2026-11-12 Edits parked in the autostash freeze clone updates and deployed files — git leaves conflict markers in the clone, which must not be deployed.
- 2026-11-12 A merged `statusline.js` is deployed only after `node --check` — a clean text merge can still break code.
- 2026-11-12 Preview never rebases — it promises to write nothing, and a rebase rewrites local commits.
- 2026-11-12 An edited file whose base is not in the history is kept in every mode; only `-Apply -Force` replaces it — no mode drops an edit silently.
