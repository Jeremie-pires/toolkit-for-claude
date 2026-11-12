# Spec: safe-sync

## Objective
Auto-sync must bring in the kit's upstream changes without destroying, or getting blocked by, what the user changed on their machine. Today two things go wrong:

1. **In the kit clone** (`~/.claude-kit`), `git merge --ff-only` fails as soon as the clone has an uncommitted edit to a file that also changed upstream. The whole update is skipped, at every launch, with a `kit!` warning.
2. **In the deployed files** (`~/.claude/CLAUDE.md`, `~/.claude/statusline.js`), `Sync-File` replaces the whole file. In `-Quiet` mode a local edit blocks the update; a manual `-Apply` backs the edit up and replaces it.

Target user: someone running the kit from their own fork on one or more machines, who sometimes edits the kit files in place instead of going through their fork.

Success: upstream changes land automatically when they don't overlap local edits; when they do overlap, nothing local is lost, nothing half-merged is deployed, and the warning says exactly what to do.

## Capability map

| Module id | Responsibility | Depends on |
|---|---|---|
| `rules-home` | Make `~/.claude/rules/` the documented home for machine-local content | — |
| `clone-rebase` | Rebase the kit clone onto upstream, carrying local commits and uncommitted edits | — |
| `file-merge` | Three-way merge of the deployed files against the last version the kit wrote | `clone-rebase` |

Build order: `rules-home`, `clone-rebase` (either order), then `file-merge`. The three modules share one script and one test file, so they stay in this one spec.

## Module `rules-home`
Ownership rule: files the kit deploys belong to the kit; machine-local additions belong in `~/.claude/rules/`, which Claude Code loads in every project and the kit never writes inside.

- `bootstrap.ps1 -Apply` creates `~/.claude/rules/` when it is missing (empty folder, no file). Preview mode reports `~ would create <path>`. It never reads, writes or deletes anything inside the folder. (Also closes the `AI_STATE.md` next step "bootstrap.ps1 creates or reports ~/.claude/rules/".)
- Every warning about a local edit to a deployed file ends with: `machine-local content belongs in <claude>/rules/`.
- README: the Customize section states the ownership rule above, in one place; the "What it touches" table lists the folder creation.

## Module `clone-rebase`
Replace step 1's `git merge --ff-only --quiet '@{u}'` with a rebase that carries local work.

Behavior, after a successful fetch and the existing review hold (unchanged: `Get-HeldChanges` compares `HEAD...@{u}`, so only upstream changes are held):

| Clone state | Result |
|---|---|
| Clean, no local commits | Fast-forward (same as today) |
| Local commits, no conflict | Local commits replayed on top of `@{u}` |
| Uncommitted edits to tracked files, no conflict | Edits kept in the working tree after the update |
| Untracked files (e.g. a local assets folder) | Left untouched |
| Conflict in a local commit, or an untracked file in the way | Clone back to its exact state before the run; warning; local copy used |
| Uncommitted edits that clash with upstream when re-applied | Clone at `@{u}`, edits kept in the stash and in the tree with conflict markers; warning with recovery steps; deployed files not synced (see below) |

Implementation outline:

```powershell
$null = & git -C $KitDir rebase --autostash --quiet '@{u}' 2>&1
if ($LASTEXITCODE -ne 0) {
  $null = & git -C $KitDir rebase --abort 2>&1   # also re-applies the autostash
  Warn "kit update skipped: local changes in $KitDir conflict with upstream; run git -C $KitDir pull --rebase --autostash and resolve, then bootstrap.ps1 -Apply"
}
```

- Autostash re-apply conflict: git completes the rebase, keeps the edits in the stash list ("Your changes are safe in the stash") and also leaves the failed re-apply in the working tree, with conflict markers in the files that clashed. Detect it by the stash entry's subject, which git sets to `autostash` (`git stash list --format=%gd%x09%gs`), so a stash the user made by hand is never mistaken for it. The run does not resolve anything itself. It sets `$stashPending = $true` and warns with the conflicted files and the recovery steps: resolve the markers, `git -C <KitDir> reset -q` (clears the unmerged state, keeps the edits), then `git -C <KitDir> stash drop <ref>`. It skips the deployed-file sync, so neither a tree with markers nor a tree without the user's edits is deployed.
- Preview (no `-Apply`) fetches but never rebases: it prints `~ would fast-forward the kit by N upstream commit(s)` or `~ would rebase L local commit(s) onto N upstream commit(s)`, with `, carrying uncommitted edits` when the tree has them, or `= kit up to date`.
- At the start of every run, throttled or not, such an entry also sets `$stashPending` and the run skips the update itself, so later launches neither bury the parked edits under more upstream changes nor sync files, and keep warning until the user follows the recovery steps.
- `lastPull` and `$pulled` keep their meaning: `$pulled` is true when `HEAD` moved.

## Module `file-merge`
Replace `Sync-File`'s "overwrite or keep" with a three-way merge. Applies to `CLAUDE.md`, and to `statusline.js` with the extra check in Resolved questions.

Base storage: after each successful write the kit copies the kit's version (`src`) to `<claude>/claude-kit-base/<key>`. That copy is the merge base next time. `claude-kit-sync.json` keeps `applied[<key>]` = hash of what was written to `dst`.

Decision table (`base` = stored copy, `src` = kit's file, `dst` = deployed file):

| Case | Action |
|---|---|
| `src` missing | Nothing |
| `dst` missing | Copy `src`; store base |
| `dst` = `src` | Store base if missing; nothing else |
| `src` = `base` (kit unchanged) | Keep `dst` |
| `dst` = `base`, or no base and `dst` hash = `applied` (not edited) | Back up `dst`, copy `src`, store base |
| Both changed, `git merge-file -p dst base src` exits 0 | Back up `dst`, write the merged text, store base |
| Both changed, merge conflicts | Keep `dst`; write the merged text with conflict markers to `<dst>.kit-merge`; warning naming that file |
| No base and `dst` edited (installs from before this change) | Look for the base in the clone's history: hash each `git log` version of `global/<key>` and match `applied[<key>]`. Found: merge as above. Not found: keep `dst`, warning (same text as today plus the `rules-home` hint) |

- `git merge-file` labels: `-L local -L kit-base -L kit`.
- Preview mode prints the action the table picks (`~ would merge`, `~ conflict, would write <dst>.kit-merge`) and writes nothing.
- Skipped entirely when `$stashPending` is set (see `clone-rebase`).
- A stale `<dst>.kit-merge` is deleted once a later run merges or copies cleanly.
- The `.kit-merge` file and `claude-kit-base/` are not `.md` files under `rules/` or `CLAUDE.md`, so Claude Code never loads them.

## Tech stack
PowerShell 5.1+ (`bootstrap.ps1`), git 2.x (`rebase --autostash`, `merge-file`), no new dependency.

## Commands
- Test: `powershell -NoProfile -File tests/safe-sync.tests.ps1`
- Existing suites (must stay green): `powershell -NoProfile -File tests/review-guard.tests.ps1`, `powershell -NoProfile -File tests/bootstrap-checks.tests.ps1`, `node --test`
- Manual preview: `& "$HOME\.claude-kit\bootstrap.ps1"`

## Project structure
- `bootstrap.ps1`: new functions `Update-KitClone` (module `clone-rebase`) and `Merge-KitFile` (module `file-merge`, replaces `Sync-File`); folder creation in step 3.
- `tests/safe-sync.tests.ps1`: new suite.
- `README.md`: Customize section, "What it touches", Troubleshooting rows for the two new warnings.
- `AI_STATE.md`: decisions, via `/toolkit:save-state` at the end.

## Code style
Match `bootstrap.ps1`: small named functions, `Say` / `Warn` for output, git called as `& git -C $dir ... 2>&1` with `$LASTEXITCODE` checked right after, comments only for the non-obvious "why".

```powershell
# The kit's version from the last write is the merge base; without it a local edit cannot be told from an upstream one
function Merge-KitFile($src, $dst, $key) {
  ...
}
```

## Testing strategy
`tests/safe-sync.tests.ps1`, plain PowerShell assertions like the other suites (no Pester). Functions are loaded from `bootstrap.ps1` through the AST, as in `bootstrap-checks.tests.ps1`, so the script itself never runs. Each case builds throwaway repos in `$env:TEMP`: a bare "upstream", a clone acting as the kit, and a fake config folder.

`clone-rebase` cases: one per row of its table, plus autostash re-apply conflict (stash kept, `$stashPending` set, warning text) and a pending autostash found at start.

`file-merge` cases: one per row of its decision table, plus preview writes nothing, skip when `$stashPending`, stale `.kit-merge` removed, history lookup for a legacy install.

`rules-home` cases: folder created when missing, existing folder and its files untouched, preview creates nothing.

## Boundaries
- Always: leave the user's edits recoverable (working tree, stash, backup or `.kit-merge`) in every failure path; keep the review hold exactly as strict as today; keep `-Quiet` runs silent apart from recorded warnings.
- Ask first: merging any file other than `CLAUDE.md` and `statusline.js`; changing the review pattern; changing the state file format beyond what this spec lists.
- Never: write conflict markers into a deployed file; run `reset --hard`, `clean`, `checkout --` or `stash drop` in the clone; read or write inside `~/.claude/rules/`; push from the clone.

## Success criteria
1. Clone with an uncommitted edit to `global/CLAUDE.md` and a non-overlapping upstream change to the same file: after `-Apply -Quiet`, the clone is at `@{u}` with the edit still in the working tree, and no warning.
2. A local commit, or an untracked file, that clashes with an upstream change: clone byte-identical to before (HEAD, working tree, stash list), one warning. (An overlapping uncommitted edit is criterion 5.)
3. Deployed `CLAUDE.md` with a local section, upstream change elsewhere in the file: after the run, the file holds both, a backup exists, no warning.
4. Overlapping edit in the deployed file: file unchanged, `CLAUDE.md.kit-merge` holds conflict markers, one warning naming it.
5. Autostash conflict: the edits are in `stash@{0}`, deployed files unchanged, warning repeats at every run, throttled or not, until the user follows its steps; after them the next run updates normally.
6. `~/.claude/rules/` exists after `-Apply`; its contents are never modified.
7. All four test suites pass.

## Resolved questions (2026-11-12)
1. **`statusline.js`** is merged like `CLAUDE.md`, then checked with `node --check`. A failed check, or no `node` on PATH, is handled like a conflict: `dst` kept, merged text in `statusline.js.kit-merge`, warning.
2. **Autostash re-apply conflict**: the edits stay in the stash; the run never resolves or drops it. The warning repeats at every launch until the user follows its recovery steps.
3. **Legacy edited file with no base found**: kept with a warning in every mode, including a manual `-Apply`. Only `-Apply -Force` backs it up and replaces it (today's manual behavior).
