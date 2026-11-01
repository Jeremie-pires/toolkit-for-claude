# Spec: review-guard

## Objective
Auto-sync (`bootstrap.ps1 -Apply -Quiet`, run by the `SessionStart` hook) fast-forwards the kit clone. Today it holds back upstream changes to `bootstrap.ps1`, `global/settings.base.json`, `global/statusline.js` and `plugins/*/hooks/`, but not to other executable files in a plugin. A script such as `plugins/toolkit/scripts/dream-digest.mjs` would run on every machine without review. Close that gap.

## Change
Widen `$reviewPattern` in `bootstrap.ps1` so it also matches any file under `plugins/` with an executable extension: `.ps1`, `.psm1`, `.js`, `.mjs`, `.cjs`, `.ts`, `.py`, `.sh`, `.bat`, `.cmd`.

```powershell
$reviewPattern = '^(bootstrap\.ps1|global/settings\.base\.json|global/statusline\.js)$|^plugins/[^/]+/hooks/|^plugins/.+\.(ps1|psm1|js|mjs|cjs|ts|py|sh|bat|cmd)$'
```

Update the matching text in the `.DESCRIPTION` block, the README security notes and the decision in `AI_STATE.md`.

## Commands
- Test: `powershell -NoProfile -File tests/review-guard.tests.ps1`
- Manual check: `& "$HOME\.claude-kit\bootstrap.ps1"` (preview) after an upstream change to a plugin script prints the "wait for review" warning.

## Project structure
- `bootstrap.ps1`: the pattern.
- `tests/review-guard.tests.ps1`: plain PowerShell assertions, no Pester dependency. Tests stay outside `plugins/` so they are not shipped in the plugin.

## Testing strategy
A table of paths with the expected result:

| Path | Held back |
|---|---|
| `bootstrap.ps1` | yes |
| `global/statusline.js` | yes |
| `plugins/toolkit/hooks/hooks.json` | yes |
| `plugins/toolkit/scripts/dream-digest.mjs` | yes |
| `plugins/toolkit/skills/x/run.py` | yes |
| `plugins/toolkit/commands/dream.md` | no |
| `plugins/toolkit/skills/humanizer/SKILL.md` | no |
| `global/CLAUDE.md` | no |
| `README.md` | no |

## Boundaries
- Always: keep the pattern in one place; keep markdown files auto-synced.
- Ask first: holding back any non-executable path.
- Never: weaken an existing match.

## Success criteria
- Every row of the table passes.
- A preview run with an upstream change to a plugin script lists it as waiting for review and does not fast-forward in `-Quiet` mode.
