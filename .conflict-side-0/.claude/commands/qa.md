Dispatch QA work against the `web/` app. Two paths:

- **Default (isolated)**: spawn the `qa-web-agent` subagent via the Agent tool. The subagent reads `.claude/skills/qa-web/SKILL.md` as its first action and follows it. Best for full exploratory/author/heal runs — keeps the main thread clean. Note: the "black-box" tool boundary is prompt-level discipline, not a hard sandbox; the real value is context isolation.
- **Inline**: invoke the `qa-web` skill directly in the current thread. Best when composing QA with other work (e.g. after a `/code-review`), or for a quick check like `/qa ledger`. Use `/qa inline ...` to force this path.

## Argument parsing

Parse what the user typed after `/qa`:

| Input | Path | What to run |
|---|---|---|
| *(empty)* or `explore` | subagent | Phase 0 (Scope) → Phase 1 (Explore, scoped to P0/P1) |
| `explore <area>` | subagent | Phase 1 scoped to `<area>`. Skip Phase 0. |
| *free-form change summary* (e.g. `/qa we rewrote auth middleware`) | subagent | Phase 0 treats summary as authoritative intent → Phase 1 |
| `author <slug-or-spec-path>` | subagent | Phase 2: spec → human gate → Generator |
| `heal [test-path]` | subagent | Phase 3: selector-drift vs regression triage |
| `run` | inline | Just `mise run web:check && mise run web:e2e`; summarize pass/fail |
| `ledger` | inline | Summarize `web/tests/LEDGER.md` gaps |
| `inline <rest>` | inline | Force inline path for any of the above |
| `doctor` | inline | Run `.claude/skills/qa-web/scripts/doctor.sh`; print results |

**Fallthrough:** any argument that does not begin with one of the reserved keywords above (`explore`, `author`, `heal`, `run`, `ledger`, `inline`, `doctor`) is treated as a **free-form change summary** and routed to the subagent path. Example: `/qa we rewrote the auth middleware` → subagent with Phase 0 receiving that string as authoritative intent.

## Subagent path

Use the Agent tool:

```
Agent({
  subagent_type: "qa-web-agent",
  description: "<short>",
  prompt: "<verbatim user arg after /qa, or 'bare /qa' if empty>"
})
```

The subagent will invoke the `qa-web` skill, run through the phases, and return a single `## qa-web report` block. Relay that report to the user as-is.

## Inline path

Invoke the `qa-web` skill directly via the Skill tool:

```
Skill({ skill: "qa-web", args: "<user args>" })
```

The skill's SKILL.md describes the normal flow. The tool boundary is advisory in this path — rely on your own discipline to follow the invariants (no `web/src/**` reads during Explore, spec-first during Author, etc.).

## Never

- Do not open PRs from either path. Summarize diff + evidence; let the human review.
- Do not skip doctor. Both paths run it first via the skill.
- Do not narrate what the subagent is doing in real time — wait for its report and relay it.
