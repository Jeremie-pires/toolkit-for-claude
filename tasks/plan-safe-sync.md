# Implementation plan: safe-sync

## Overview
Build [docs/specs/SPEC-safe-sync.md](../docs/specs/SPEC-safe-sync.md): auto-sync rebases the kit clone with `--autostash` instead of fast-forwarding, merges the deployed `CLAUDE.md` and `statusline.js` three ways against the last version the kit wrote, and creates `~/.claude/rules/` as the home for machine-local content. Nothing local is lost in any failure path.

## Architecture decisions
- **Riskiest part first.** `clone-rebase` comes first: its git behavior (abort, autostash re-apply, untracked files in the way) decides whether the rest of the design holds.
- **Testable functions, not script runs.** The new logic lives in `Update-KitClone` and `Merge-KitFile`. The tests load them from `bootstrap.ps1` through the AST, as `bootstrap-checks.tests.ps1` does, and stub `Say` and `Warn` to collect messages. Like `Sync-File`, the functions read `$Apply`, `$Quiet`, `$Force` and `$applied` from script scope; the tests set them.
- **Throwaway repos.** Each test case builds a bare "upstream" and a clone in `$env:TEMP`, with `core.autocrlf=false` and a local user name and email, so results do not depend on the machine's git config.
- **`Update-KitClone` returns its outcome** (`pulled`, `stashPending`) instead of setting globals, so step 3 can skip the file merge when edits are parked in the stash.
- **Base copies on disk** in `<claude>/claude-kit-base/`, not git objects: the deployed version can come from an uncommitted working tree, which has no commit to point at.
- **One shared test file**, `tests/safe-sync.tests.ps1`, grown task by task.

## Dependency graph
```
Task 1: rebase + abort ───► Task 2: autostash pending
                                   │
Task 3: rules-home (independent)   │
          │                        │
          └──────── Checkpoint 1 ──┘
                        │
              Task 4: Merge-KitFile core
                        │
              Task 5: legacy base lookup + -Force
                        │
              Task 6: statusline.js check + stash skip
                        │
                   Checkpoint 2
                        │
              Task 7: docs and state
                        │
                   Checkpoint 3
```

## Task list
See [todo-safe-sync.md](todo-safe-sync.md) for acceptance criteria and verification.

### Phase 1: Clone and rules folder
- [x] Task 1: Rebase the clone with `--autostash`, abort on conflict
- [x] Task 2: Detect edits parked in the autostash
- [x] Task 3: Create `~/.claude/rules/` and point warnings at it

### Checkpoint 1
- [x] All suites pass; `/code-review low`

### Phase 2: Deployed files
- [x] Task 4: Three-way merge of `CLAUDE.md`
- [x] Task 5: Base lookup for existing installs, `-Force` replace
- [x] Task 6: `statusline.js` syntax check, skip while the stash is pending

### Checkpoint 2
- [x] All suites pass; `/code-review low`

### Phase 3: Docs and rollout
- [x] Task 7: README, script header, state

### Checkpoint 3 (complete)
- [x] Spec success criteria 1 to 7 met; `/toolkit:save-state`; push; rollout on this machine

## Risks and mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| **Bootstrapping problem**: the new `bootstrap.ps1` is held for review, and the old one on each machine still does `merge --ff-only`, which fails on a clone with local edits | High | Rollout step at Checkpoint 3: run `git -C ~/.claude-kit pull --rebase --autostash` by hand once, then `bootstrap.ps1 -Apply`. Documented in the README for existing installs |
| `rebase --abort` leaves the clone different from before (e.g. rebase refused before it started, nothing to abort) | High | Test compares HEAD, `git status --porcelain` and `git stash list` before and after for every conflict case |
| Autostash re-apply conflict exit code or message differs across git versions | Med | Detection relies on the stash entry's `autostash` subject, not on the exit code or the message text |
| Line endings make `src`, `base` and `dst` differ by CRLF only | Med | Test cases with CRLF files; hashes compare raw bytes like today's `FileHash`, and `merge-file` runs on the files as they are |
| `node` missing on a machine | Low | Treated like a failed check (spec, resolved question 1): `dst` kept, warning |
| A test leaves temp repos behind | Low | Each case removes its temp folder in a `finally` |
