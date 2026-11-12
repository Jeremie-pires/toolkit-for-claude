# Tasks: safe-sync

## Task 1: Rebase the clone with `--autostash`, abort on conflict
**Description:** Move step 1's fetch-and-update into `Update-KitClone`. Replace `git merge --ff-only --quiet '@{u}'` with `git rebase --autostash --quiet '@{u}'`; on failure run `git rebase --abort` and warn with the command to resolve by hand. Keep the fetch throttle, the review hold and `lastPull` as they are. Create `tests/safe-sync.tests.ps1` with the AST loader, `Say`/`Warn` stubs and a helper that builds a bare upstream and a clone in `$env:TEMP`.

**Acceptance criteria:**
- [x] Clean clone: fast-forward to `@{u}`, `pulled` is true.
- [x] Local commits, or uncommitted edits to tracked files, with no conflict: replayed on top of `@{u}`; edits still uncommitted afterwards; untracked files untouched.
- [x] Conflict in a local commit, or an untracked file in the way of an incoming one: HEAD, `git status --porcelain` and `git stash list` identical to before; one warning.

**Verification:**
- [x] `powershell -NoProfile -File tests/safe-sync.tests.ps1` passes
- [x] `powershell -NoProfile -File tests/review-guard.tests.ps1` and `tests/bootstrap-checks.tests.ps1` still pass

**Dependencies:** None
**Files:** `bootstrap.ps1`, `tests/safe-sync.tests.ps1`
**Scope:** M

## Task 2: Detect edits parked in the autostash
**Description:** After the rebase, a stash entry whose subject is `autostash` means git could not re-apply the edits: return `stashPending = $true` and warn with the conflicted files and the recovery steps (resolve, `reset -q`, `stash drop`). At the start of every run, throttled or not, such an entry also sets `stashPending` and the warning, and the update is skipped. Preview never rebases (Checkpoint 1 review).

**Acceptance criteria:**
- [x] Uncommitted edit that conflicts with upstream on re-apply: the edit is in `stash@{0}`, `stashPending` is true, the warning names the conflicted file and `stash drop`; following its steps unblocks the next update.
- [x] Next run with the stash still there: same warning, `stashPending` true, no new stash entry.
- [x] A stash entry the user made by hand (other message) does not set `stashPending`.

**Verification:**
- [x] `powershell -NoProfile -File tests/safe-sync.tests.ps1` passes

**Dependencies:** Task 1
**Files:** `bootstrap.ps1`, `tests/safe-sync.tests.ps1`
**Scope:** S

## Task 3: Create `~/.claude/rules/` and point warnings at it
**Description:** In step 3, `-Apply` creates `<claude>/rules/` when missing; preview prints `~ would create <path>`. Add the hint `machine-local content belongs in <claude>/rules/` to the warning `Sync-File` raises for a local edit (Task 4 reuses it).

**Acceptance criteria:**
- [x] Missing folder: created by `-Apply`, not by preview.
- [x] Existing folder with files: files unchanged (same names, hashes and timestamps).
- [x] The local-edit warning ends with the hint.

**Verification:**
- [x] `powershell -NoProfile -File tests/safe-sync.tests.ps1` passes

**Dependencies:** None
**Files:** `bootstrap.ps1`, `tests/safe-sync.tests.ps1`
**Scope:** XS

## Checkpoint 1
- [x] All four suites pass (`safe-sync`, `review-guard`, `bootstrap-checks`, `node --test`)
- [x] `/code-review low` on the diff; findings answered (2 found, both fixed)
- [x] Review with the user before Phase 2

## Task 4: Three-way merge of `CLAUDE.md`
**Description:** Replace `Sync-File` with `Merge-KitFile`, following the spec's decision table: store `src` in `<claude>/claude-kit-base/<key>` after each write, merge with `git merge-file -p -L local -L kit-base -L kit` when both sides changed, write conflicts to `<dst>.kit-merge` and never into `dst`, delete a stale `.kit-merge` after a clean run. Preview prints the chosen action and writes nothing. `applied[<key>]` keeps the hash of what was written to `dst`.

**Acceptance criteria:**
- [x] Each row of the decision table except the legacy row gives the expected `dst`, base copy, `.kit-merge` and warning.
- [x] Spec success criteria 3 and 4 hold on fixture files, including a CRLF case.
- [x] Preview mode leaves every file and folder as it was.

**Verification:**
- [x] `powershell -NoProfile -File tests/safe-sync.tests.ps1` passes

**Dependencies:** Task 3
**Files:** `bootstrap.ps1`, `tests/safe-sync.tests.ps1`
**Scope:** M

## Task 5: Base lookup for existing installs, `-Force` replace
**Description:** When no base copy exists and `dst` was edited, hash each `git log` version of `global/<key>` in the clone and use the one matching `applied[<key>]` as the base. Not found: keep `dst` and warn in every mode; only `-Apply -Force` backs it up and replaces it.

**Acceptance criteria:**
- [x] Legacy install whose applied version is in the history: merged as in Task 4, base copy created.
- [x] Not in the history: `dst` kept with `-Apply -Quiet` and with `-Apply`; backed up and replaced with `-Apply -Force`.

**Verification:**
- [x] `powershell -NoProfile -File tests/safe-sync.tests.ps1` passes

**Dependencies:** Task 4
**Files:** `bootstrap.ps1`, `tests/safe-sync.tests.ps1`
**Scope:** S

## Task 6: `statusline.js` syntax check, skip while the stash is pending
**Description:** Run `statusline.js` through `Merge-KitFile`, then `node --check` on a merged result before writing it. A failed check, or no `node` on PATH, is handled like a conflict. Skip both files when `Update-KitClone` reports `stashPending`.

**Acceptance criteria:**
- [x] A clean merge that breaks JS syntax: `dst` kept, `statusline.js.kit-merge` written, warning.
- [x] `node` not found: same handling.
- [x] `stashPending`: neither file is touched, no base copy updated (the skip itself landed at Checkpoint 1; this task keeps it for `Merge-KitFile`).

**Verification:**
- [x] `powershell -NoProfile -File tests/safe-sync.tests.ps1` passes
- [x] Spec success criterion 5 holds end to end in a throwaway setup

**Dependencies:** Tasks 2 and 5
**Files:** `bootstrap.ps1`, `tests/safe-sync.tests.ps1`
**Scope:** S

## Checkpoint 2
- [x] All four suites pass
- [x] `/code-review low` on the diff; findings answered (1 found, fixed)
- [x] Review with the user before Phase 3

## Task 7: README, script header, state
**Description:** Update the `.DESCRIPTION` block (what the script touches, rebase instead of fast-forward, `.kit-merge`), the README (ownership rule in Customize, "What it touches", Troubleshooting rows for the rebase, stash and `.kit-merge` warnings, one-time manual pull for existing installs) and the `AI_STATE.md` next step about `~/.claude/rules/`.

**Acceptance criteria:**
- [x] Every new warning has a Troubleshooting row with the fix.
- [x] The README states the ownership rule once and the other sections link to it.
- [x] The one-time rollout command for existing installs is documented.

**Verification:**
- [x] The user reads the README diff
- [x] `toolkit:humanizer` pass on the new README text

**Dependencies:** Task 6
**Files:** `bootstrap.ps1`, `README.md`
**Scope:** S

## Checkpoint 3
- [x] Spec success criteria 1 to 7 met
- [x] `/toolkit:save-state`; commit; push (asks first)
- [x] Rollout on this machine: `git -C ~/.claude-kit pull --rebase --autostash`, resolve if needed, then `bootstrap.ps1 -Apply`; the local edit to `global/CLAUDE.md` and the untracked `Capgemini/` survive (the edit hit the autostash conflict; it now lives in `~/.claude/rules/`, the ownership rule's home; the plugin had to be refreshed by hand, which led to the plugin-refresh fix)
