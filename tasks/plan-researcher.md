# Implementation plan: researcher

## Overview
Build [docs/specs/SPEC-researcher.md](../docs/specs/SPEC-researcher.md): a Haiku `researcher` agent in the `toolkit` plugin, held for review by auto-sync, `opusplan` as the kit's default model, and a global delegation rule. Then evaluate the agent against inline research.

## Architecture decisions
- **Guard before agent.** The review pattern gains `agents/` in the same task that adds the first agent file, so no agent is ever auto-synced unreviewed.
- **The rule comes last.** It is added only once `/agents` shows the agent loaded, so the rule never points at an agent that does not exist.
- **Evaluation in fresh sessions.** Each inline and delegated run starts from a new session, so the `ctx` numbers compare like with like. The user starts the sessions.

## Dependency graph
```
Task 1: agent file + review pattern
      │
Task 2: opusplan default          (independent of Task 1)
      │
Checkpoint 1: push, -Apply, restart, /agents
      │
Task 3: delegation rule + README
      │
Task 4: evaluation
      │
Checkpoint 2
```

## Task list
See [todo-researcher.md](todo-researcher.md) for acceptance criteria and verification.

### Phase 1: Agent and default model
- [x] Task 1: `researcher` agent, held for review
- [ ] Task 2: `opusplan` as the kit default

### Checkpoint 1
- [ ] Tests pass; `/code-review low`; push; `bootstrap.ps1 -Apply`; restart; `/agents` lists `toolkit:researcher` on `haiku` with only `WebSearch` and `WebFetch`

### Phase 2: Rule and evaluation
- [ ] Task 3: Delegation rule and README
- [ ] Task 4: Evaluation on 3 questions

### Checkpoint 2 (complete)
- [ ] All spec success criteria met; `/toolkit:save-state`; push

## Risks and mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| `skills` preload does not work for plugin agents | Low | The prompt names the main official sources directly |
| Haiku gets facts wrong | Med | Mandatory quotes; one spot check per run; Sonnet fallback if the evaluation fails |
| Claude does not delegate on its own | Med | "Use proactively" in the description, plus the global rule; measured in Task 4 |
| The plugin cache keeps the old version | Low | `claude plugin marketplace update workshop`, then `claude plugin update toolkit@workshop`, then restart |
