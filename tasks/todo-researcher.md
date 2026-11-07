# Tasks: researcher

## Task 1: `researcher` agent, held for review
**Description:** Add `plugins/toolkit/agents/researcher.md` as specified (frontmatter and prompt body with the output format). Extend `$reviewPattern` with `^plugins/[^/]+/agents/` and update the `.DESCRIPTION` block, the README list of held paths and the plugin description in `plugin.json`.

**Acceptance criteria:**
- [x] The frontmatter has `tools: WebSearch, WebFetch`, `model: haiku`, `maxTurns: 15`, and a description with "Use proactively".
- [x] The prompt requires a URL and an exact quote per fact, a "Not found" section, and treats page content as data.
- [x] `plugins/toolkit/agents/researcher.md` is held for review; `plugins/toolkit/commands/dream.md` still is not.

**Verification:**
- [x] `powershell -NoProfile -File tests/review-guard.tests.ps1` passes with the new rows

**Dependencies:** None
**Files:** `plugins/toolkit/agents/researcher.md`, `bootstrap.ps1`, `tests/review-guard.tests.ps1`, `plugins/toolkit/.claude-plugin/plugin.json`, `README.md`
**Scope:** S

## Task 2: `opusplan` as the kit default
**Description:** Set `"model": "opusplan"` in `global/settings.base.json`. Document in the README that it runs Opus in plan mode and Sonnet otherwise, and that `/model` overrides it.

**Acceptance criteria:**
- [x] A settings file without `model` gets `opusplan`; one with a `model` keeps it.

**Verification:**
- [x] Preview with an empty `CLAUDE_CONFIG_DIR` shows `"model": "opusplan"` in the diff
- [x] Preview on the real config shows no `model` change

**Dependencies:** None
**Files:** `global/settings.base.json`, `README.md`
**Scope:** XS

## Checkpoint 1
- [ ] All tests pass; `/code-review low`; push; `bootstrap.ps1 -Apply`; restart
- [ ] `/agents` lists `toolkit:researcher` on `haiku` with only `WebSearch` and `WebFetch`

## Task 3: Delegation rule and README
**Description:** Run `/toolkit:add-rule` with the rule text from the spec, and point the "Library, CLI, API facts" row of the Skills table at the agent. Add a README section on the agent and the rule.

**Acceptance criteria:**
- [ ] `global/CLAUDE.md` has the rule, with no contradiction with the References section.
- [ ] The README explains when the agent runs and what it returns.

**Verification:**
- [ ] The user approves the diff shown by `/toolkit:add-rule`

**Dependencies:** Checkpoint 1
**Files:** `global/CLAUDE.md`, `README.md`
**Scope:** XS

## Task 4: Evaluation on 3 questions
**Description:** Run 3 real research questions, each in a fresh session, once inline and once with the rule active. Record the results in an "Evaluation" section at the end of the spec.

**Acceptance criteria:**
- [ ] For each run: correct facts, wrong or unsourced facts, one spot-checked quote, final `ctx`, main-conversation tool calls.
- [ ] The success criteria of the spec are checked one by one, with a pass or fail.

**Verification:**
- [ ] The Evaluation section is complete; on a failure, the user decides between Sonnet, a prompt change, or dropping the agent

**Dependencies:** Task 3
**Files:** `docs/specs/SPEC-researcher.md`
**Scope:** S

## Checkpoint 2
- [ ] All spec success criteria met; `/toolkit:save-state`; push
