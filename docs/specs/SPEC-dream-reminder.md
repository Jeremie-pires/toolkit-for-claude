# Spec: dream-reminder

## Objective
Remind the user to run `/toolkit:dream` without spending tokens: the status line shows how long ago the current project was last dreamed, once that is more than 7 days.

## Behavior
- `global/statusline.js` reads `~/.claude/claude-kit-dream.json` and looks up the current project (`workspace.project_dir`, falling back to the existing `dir` logic).
- Shown on line 1, after the kit warnings:
  - last dream 8 days ago or more: `dream 9d` in orange;
  - past 25 days: `dream 27d!` in red, because transcripts start being deleted at 30 days by default;
  - never dreamed: `dream?` in white;
  - 7 days or less: nothing.
- A missing or unreadable file means "never dreamed"; it never breaks the status line.
- Projects that are not git repositories show nothing, so home or temp folders stay quiet.

## Commands
- Test: `node --test`
- Manual check: run a dream, restart Claude Code, confirm the segment disappears.

## Project structure
- `global/statusline.js`: the new segment (held back by auto-sync; applied with a manual `-Apply`).
- `tests/statusline-dream.test.mjs`: spawns the status line with a stdin JSON and a temporary home folder.

## Code style
Same as the existing kit-warnings segment:

```js
dreamAge !== null && dreamAge > 7 && `${dreamAge > 25 ? C.red : C.orange}dream ${dreamAge}d${dreamAge > 25 ? '!' : ''}${R}`,
```

## Boundaries
- Always: read-only, fail silent.
- Never: write files or call the network from the status line.

## Success criteria
- The 4 states render as specified in tests.
- The status line still renders when the file is missing or corrupt.
