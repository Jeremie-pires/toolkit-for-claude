# Project state
_Updated: 2026-10-27_

## Done
- Public-readiness pass pushed: `origin/main` at `0138cc6`. The repo is public and installed on this machine from a fresh pull.
- `bootstrap.ps1` derives the `workshop` marketplace from the clone's `origin`; `-Repo` has no default and is only used for a first clone.
- Plugin renamed `claude-kit` to `toolkit`. `marketplace.json` has `renames: { "claude-kit": "toolkit" }`. The bootstrap drops the old `enabledPlugins` key and uninstalls `claude-kit@workshop` only after `toolkit@workshop` is installed.
- `global/CLAUDE.md` replies in the user's language; personal overrides go in `~/.claude/rules/`.
- MIT `LICENSE`; upstream licenses kept for the bundled skills.
- History checked: commits use the GitHub noreply email, no secrets or token formats found.
- Security and licensing audit of the public repo; fixes in the working tree (see Current state).

## Current state
Public repo. Marketplace `workshop` lists one plugin, `toolkit` (`plugins/toolkit/`: 4 commands, 3 skills). `bootstrap.ps1` syncs `global/` into `~/.claude` and installs missing plugins, from an async `SessionStart` hook. Uncommitted audit fixes: auto-sync holds back upstream changes to executable files, permanent `.pre-kit` backups, preview temp files deleted, CC BY-SA notice for the humanizer skill, public-safe rule for `AI_STATE.md`.

## Next steps
1. Review and commit the audit fixes, push, then on each machine run `bootstrap.ps1 -Apply` once.
2. Browse public mods for anything worth adding to `workshop`; no mod is planned for now.

## Open issues
- Bash deny rules match prefixes only (`/bin/rm -rf`, `bash -c "..."` get through); documented in the README, no fix planned.

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
