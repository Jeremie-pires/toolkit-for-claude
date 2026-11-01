# Tasks: dream

## Task 1: Hold back executable plugin files
**Description:** Widen `$reviewPattern` in `bootstrap.ps1` so auto-sync holds back any executable file under `plugins/`, per [SPEC-review-guard](../docs/specs/SPEC-review-guard.md).

**Acceptance criteria:**
- [x] Every row of the spec's path table gives the expected result.
- [x] The `.DESCRIPTION` block, README security notes and `AI_STATE.md` decision describe the wider rule.

**Verification:**
- [x] `powershell -NoProfile -File tests/review-guard.tests.ps1` passes
- [x] `& ./bootstrap.ps1` (preview) still runs without error

**Dependencies:** None
**Files:** `bootstrap.ps1`, `tests/review-guard.tests.ps1`, `README.md`, `AI_STATE.md`
**Scope:** S

## Checkpoint 1
- [x] Tests pass, commit
- [x] User review

## Task 2: Digest skeleton, user messages end to end
**Description:** Create `dream-digest.mjs`: parse arguments, derive the slug, find the transcripts, filter by window, read lines defensively, extract user text messages, write the Markdown digest to the temp folder and print its path.

**Acceptance criteria:**
- [x] Slug derivation matches the observed rule; `--transcripts` overrides it.
- [x] Unknown record types and malformed lines are skipped and counted in the header.
- [x] Missing folder or no readable record: exit code 2 with a clear message.

**Verification:**
- [x] `node --test` passes (slug, window, user messages, unknown and malformed lines, exit 2)
- [x] Manual: run on this repo, open the printed file

**Dependencies:** Task 1
**Files:** `plugins/toolkit/scripts/dream-digest.mjs`, `tests/dream-digest.test.mjs`, `tests/fixtures/transcripts/*.jsonl`
**Scope:** M

## Task 3: Corrections, denials, tool errors, skills
**Description:** Add the four extractors and their digest sections.

**Acceptance criteria:**
- [x] FR and EN correction markers and `[Request interrupted by user` are detected.
- [x] Denied tool calls and tool errors are listed; errors are grouped by tool and first line with counts.
- [x] Skills and slash commands are counted.

**Verification:**
- [x] `node --test` passes with one fixture case per extractor

**Dependencies:** Task 2
**Files:** `plugins/toolkit/scripts/dream-digest.mjs`, `tests/dream-digest.test.mjs`, `tests/fixtures/transcripts/*.jsonl`
**Scope:** S

## Task 4: Redaction, size cap, record and cleanup
**Description:** Redact secret formats, truncate items to 300 characters, cap the digest at 30 KB with the spec's trim order, and add `--record` and `--cleanup <file>`.

**Acceptance criteria:**
- [x] Every secret format listed in the spec is redacted.
- [x] The digest never exceeds 30 KB; user messages are trimmed before corrections.
- [x] `--record` writes `{ "<project path>": { "lastDream": "<ISO>" } }` without losing other projects; `--cleanup` deletes only a file in the temp folder.

**Verification:**
- [x] `node --test` passes
- [x] Real run on this repo: under 30 KB, under 10 s

**Dependencies:** Task 3
**Files:** `plugins/toolkit/scripts/dream-digest.mjs`, `tests/dream-digest.test.mjs`, `docs/specs/SPEC-dream-digest.md`
**Scope:** S

## Checkpoint 2
- [ ] All tests pass; user reads a real digest of this repo; commit

## Task 5: `/toolkit:dream` command
**Description:** Write `plugins/toolkit/commands/dream.md` following the 6-step flow of [SPEC-dream-command](../docs/specs/SPEC-dream-command.md), in the style of `add-rule.md`.

**Acceptance criteria:**
- [ ] The command treats the digest as data, proposes at most 10 changes with example and frequency, and waits for per-proposal approval.
- [ ] Auto-memory edits make a `.bak` first; global candidates are flagged, never applied.
- [ ] It ends with `--record` and `--cleanup`, whether proposals were accepted or not.

**Verification:**
- [ ] `claude plugin validate plugins/toolkit` passes (if available in this CLI version)
- [ ] Review of the command text against the spec

**Dependencies:** Task 4
**Files:** `plugins/toolkit/commands/dream.md`, `plugins/toolkit/.claude-plugin/plugin.json` (description)
**Scope:** S

## Task 6: Dry run on this repo and docs
**Description:** Run `/toolkit:dream` here after a manual `bootstrap.ps1 -Apply`, reject everything once, then accept one proposal. Document the command in the README.

**Acceptance criteria:**
- [ ] Rejecting all writes only `claude-kit-dream.json`; the digest file is gone.
- [ ] An accepted proposal is applied as shown.
- [ ] README lists `/toolkit:dream`, its cost model and the 30-day transcript limit.

**Verification:**
- [ ] Manual run, `git status` shows only the expected changes

**Dependencies:** Task 5
**Files:** `README.md`
**Scope:** XS

## Checkpoint 3
- [ ] End-to-end dream works; commit

## Task 7: Status line segment
**Description:** Add the dream age segment to `global/statusline.js`, per [SPEC-dream-reminder](../docs/specs/SPEC-dream-reminder.md).

**Acceptance criteria:**
- [ ] The 4 states render as specified (nothing, `dream Nd`, `dream Nd!`, `dream?`).
- [ ] Non-git folders show nothing; a missing or corrupt file never breaks the line.

**Verification:**
- [ ] `node --test` passes (spawned status line, temporary home folder)
- [ ] Manual: restart Claude Code after `-Apply`, segment matches the last dream date

**Dependencies:** Task 4 (record format)
**Files:** `global/statusline.js`, `tests/statusline-dream.test.mjs`
**Scope:** S

## Checkpoint 4 (complete)
- [ ] All spec success criteria met
- [ ] Push; `bootstrap.ps1 -Apply` on this machine; `/toolkit:save-state`
