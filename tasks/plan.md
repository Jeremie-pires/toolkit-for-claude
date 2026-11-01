# Implementation plan: dream

## Overview
Build the four modules of [docs/specs/SPEC.md](../docs/specs/SPEC.md) in dependency order: `review-guard`, `dream-digest`, `dream-command`, `dream-reminder`. Each phase ends in a working, tested state and a checkpoint with the user.

## Architecture decisions
- **The script owns every deterministic step.** Besides the digest, `dream-digest.mjs` handles `--record` (writes the last-dream date to `~/.claude/claude-kit-dream.json`) and `--cleanup <file>` (deletes the digest). The model never edits that JSON or deletes files by hand. Spec updated to match.
- **Script path from the command.** `plugins/toolkit/commands/dream.md` calls `node "${CLAUDE_PLUGIN_ROOT}/scripts/dream-digest.mjs"`. Claude Code substitutes the variable inline in command content; it is not set in the Bash tool environment. Source: plugins reference, Environment variables.
- **Tests outside the plugin.** `tests/` at the repo root, `node:test` and plain PowerShell assertions, no dependency. Nothing test-related ships in the plugin cache.
- **Fixtures are synthetic.** Hand-written `.jsonl` lines shaped like the observed record types (`user`, `assistant`, `system`, `attachment`, …). Never copied from real transcripts.
- **Held-back files need a manual apply.** `bootstrap.ps1`, `global/statusline.js` and the new script are reviewed files: after each push, run `bootstrap.ps1 -Apply` on each machine.

## Dependency graph
```
review-guard (bootstrap.ps1 pattern)
      │
dream-digest (script: read → extract → redact/cap → write; --record, --cleanup)
      │
dream-command (commands/dream.md)
      │
dream-reminder (statusline.js reads claude-kit-dream.json)
```

## Task list
See [todo.md](todo.md) for acceptance criteria and verification.

### Phase 1: Guard
- [x] Task 1: Hold back executable plugin files

### Checkpoint 1
- [x] Path table passes; commit; user reviews

### Phase 2: Digest
- [x] Task 2: Digest skeleton, user messages end to end
- [x] Task 3: Corrections, denials, tool errors, skills
- [x] Task 4: Redaction, size cap, record and cleanup

### Checkpoint 2
- [x] `node --test` passes; real run on this repo under 30 KB and 10 s; user reads the digest

### Phase 3: Command
- [x] Task 5: `/toolkit:dream` command
- [ ] Task 6: Dry run on this repo and docs

### Checkpoint 3
- [ ] Dream run end to end with the user approving proposals

### Phase 4: Reminder
- [x] Task 7: Status line segment

### Checkpoint 4 (complete)
- [ ] All spec success criteria met; push; `-Apply` on this machine; `/toolkit:save-state`

## Risks and mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| The transcript format is internal and changes | Med | Defensive parser, unknown types counted and shown in the digest header, fixtures per record type |
| Keyword-based correction detection is noisy | Med | Only patterns seen 2+ times become proposals; the user approves each one |
| A transcript contains a prompt injection | High | Digest framed as data in the command; no write without approval; proposals show their evidence |
| A secret pasted in chat reaches the digest | High | Redaction before writing, temp folder only, `--cleanup` at the end, tested per format |
| Slug rule differs on another OS or version | Low | `--transcripts` override; clear exit code 2 when the folder is missing |
| `.bak` files pile up in the memory folder | Low | One `.bak` per file, overwritten on the next edit |

## Open questions
None blocking.
