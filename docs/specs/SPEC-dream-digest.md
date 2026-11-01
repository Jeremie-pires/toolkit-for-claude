# Spec: dream-digest

## Objective
A local Node script that reads one project's Claude Code transcripts and writes a small digest for the dream agent. It runs at zero token cost: it does all the filtering so the model reads tens of kilobytes instead of hundreds of megabytes.

## Input
- Project directory (default: current working directory).
- Transcript folder: `~/.claude/projects/<slug>/*.jsonl`, where `<slug>` is the project path with every character outside `[A-Za-z0-9]` replaced by `-` (observed, not documented: `C:\Users\me\Code\kit` → `C--Users-me-Code-kit`). `--transcripts <dir>` overrides it.
- Window: `--since <ISO date>`; default is the last dream date for this project from `~/.claude/claude-kit-dream.json`, else 30 days ago. Claude Code deletes transcripts after `cleanupPeriodDays` (default 30).

## Output
A Markdown file in the OS temp folder (path printed on stdout), capped at 30 KB:

```markdown
# Dream digest: <project folder name>
Window: 2026-10-01 → 2026-11-01 · 12 sessions · 3 skipped records types

## Corrections (14)
- [2026-10-28 s3] "non, utilise pnpm pas npm"
## Interruptions and denied tool calls (6)
- [2026-10-30 s7] denied Bash: `git push --force`
## Tool errors (9, grouped)
- 4× Bash: "ffprobe: command not found"
## Skills and commands used
- agent-skills:review 5 · toolkit:save-state 3
## User messages (sampled)
- [2026-10-27 s1] "..."
```

## What it extracts
- User text messages (not tool results, not system or attachment records).
- Corrections: a user message that follows an assistant turn and starts with or contains a correction marker (FR and EN: `non`, `pas ça`, `attends`, `stop`, `no`, `don't`, `wrong`, `instead`), or a `[Request interrupted by user` marker.
- Denied tool calls: tool results that report the user rejected the call.
- Tool errors: tool results flagged as errors, first line only, grouped by tool and message.
- Skills and slash commands invoked, with counts.
- It drops: assistant thinking and text, successful tool output, images, and every record type it does not know.

## Rules
- Each item is truncated to 300 characters. When the cap is reached, sections are trimmed from the bottom up (user messages first, corrections last).
- Redaction before writing: known token formats (`sk-`, `ghp_`, `gho_`, `github_pat_`, `xox[abp]-`, `AKIA`, JWT-like `eyJ…`, `Bearer …`, `password=`/`token=` values) become `[redacted]`.
- The transcript format is internal and may change. Unknown record types are skipped and counted; a malformed line is skipped, never fatal. If nothing could be read, exit code 2 with a clear message.

## Housekeeping flags
The script owns every deterministic step, so the model never edits JSON or deletes files by hand:
- `--record`: writes `{ "<project path>": { "lastDream": "<ISO date>" } }` into `~/.claude/claude-kit-dream.json`, keeping other projects.
- `--cleanup <file>`: deletes a digest, only if it sits in the OS temp folder.

## Commands
- Run: `node plugins/toolkit/scripts/dream-digest.mjs [--project <dir>] [--since <date>] [--transcripts <dir>]`
- Housekeeping: `node plugins/toolkit/scripts/dream-digest.mjs --record [--project <dir>]`, `... --cleanup <file>`
- Test: `node --test tests/`

## Project structure
- `plugins/toolkit/scripts/dream-digest.mjs`: the script (held back by `review-guard`).
- `tests/dream-digest.test.mjs`: `node:test`, no dependency.
- `tests/fixtures/transcripts/`: small synthetic `.jsonl` files. Never real transcripts.

## Code style
Plain ESM, small pure functions, explicit errors, matching `global/statusline.js`.

```js
export function isCorrection(text) {
  return CORRECTION_MARKERS.some((re) => re.test(text.trimStart()));
}
```

## Testing strategy
Unit tests on synthetic fixtures: slug derivation, window filter, each extractor, grouping, redaction of every listed format, the 30 KB cap and trim order, unknown and malformed lines.

## Boundaries
- Always: write only to the OS temp folder; redact before writing.
- Ask first: adding a dependency; reading anything outside the project's transcript folder and `claude-kit-dream.json`.
- Never: send data over the network; write into a repository; keep real transcript content in fixtures.

## Success criteria
- On this machine's transcripts for this repo, the digest is under 30 KB and the run takes under 10 s.
- Every listed secret format is redacted in tests.
- A fixture with unknown record types and broken lines produces a digest and a skipped count, not a crash.
