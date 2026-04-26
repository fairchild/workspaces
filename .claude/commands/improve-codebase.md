Improve this codebase iteratively and sustainably.

This repo is a public, exemplar codebase. No deadline. Code can be poetry — elegant and effective. Humans and AI agents should be able to read this repo and learn how to build and maintain high-quality software with coding agents. Every improvement should compound: the product gets better, and the process for improving it gets better.

## Invocation

```
/improve-codebase [desktop|web|agents|continue]
```

- `desktop` (default) — Mac app in `Sources/` and its docs/tests/scripts.
- `web` — `web/` Next.js dashboard and its Cloudflare workers.
- `agents` — `.agents/` + `.github/workflows/*agent*.yml`. Much of this is currently disabled pending security/reliability hardening.
- `continue` — resume the prior session's unit of work via `chronicle catchup`.

Stay inside the chosen focus area unless the user explicitly requests a cross-cutting change.

## Principles

- Ground before proposing. Trust nothing older than this session.
- Hypothesis → approval → work. Safe hygiene is fine while waiting; nothing meaningful ships without alignment.
- Orchestrate, don't duplicate. Subagents and teammates protect the main thread.
- Every non-trivial PR ships with uploaded evidence. See `docs/development/evidence.md`.
- Learn each cycle. Cascade process updates: this command → existing skill → new skill → open-ended proposal, in that order.
- Pause when a quick win becomes structural or a change is cross-cutting.

## Phase 1 — Orient (no approval needed)

Read live state and write yourself a short inventory. Batch these where possible.

1. **Repo state** — `git status`, current branch, open PRs (`gh pr list --state open`), recent activity (`git log --oneline -20`). If the current branch is not `main` or a working branch you intentionally chose, treat the worktree as untrusted and resolve before proposing.
2. **Roadmap** — `backlog/ROADMAP.md`. Identify active P0 theme and active milestone. **If any open PR touches `backlog/ROADMAP.md` or files in your focus area's planning surface, also read the PR-branch version (`git show origin/<branch>:<path>`) before forming hypotheses** — working-tree state is stale relative to in-flight planning changes.
3. **TODO** — `TODO.md`. These are ideas to challenge, not a worklist. Convert at most one to a backlog item per session, and only if it clearly belongs.
4. **Drift** — skim `backlog/*.md` and `docs/` for items stale relative to what the code and ROADMAP now say.
5. **Focus-area inputs**:
   - `desktop` → `config/performance/contract.json`, latest `docs/performance/*`, current baselines, known symptoms. Load the `workspaces-performance-system` skill if perf is in scope.
   - `web` → `web/docs/architecture.md`, `web/tests/LEDGER.md`, recent `web/` PRs. Consider `qa-web` if testing is in scope.
   - `agents` → `.agents/skills/*/SKILL.md`, `gh run list --workflow "Agent: April Clearwater" --limit 5`, which automations are currently gated off.
6. **Continuity** — if `continue`, run `chronicle catchup`; otherwise note any recent chronicle entries relevant to the focus area.

## Phase 2 — Propose (ASK, then WAIT)

Present one hypothesis message. Use this shape:

- **Focus area** and why — tie to ROADMAP priorities and current state.
- **State of the ground** — active milestone, in-flight PRs, pending evidence, notable drift.
- **Primary proposal** — one small, safe unit of work. Include the why, the change surface, and how we'll know it worked.
- **Next best alternative** and the tradeoff with the primary.
- **Team shape** — solo, or `TeamCreate` with N teammates. If teams, list roles, agent types, and file/module ownership boundaries so work does not collide.
- **Evidence plan** — which tests, which perf scenarios (from `config/performance/contract.json`), which uploaded artifacts prove the change.
- **Pause signals** this session will respect (defaults below, plus any session-specific additions).

Then stop and wait.

While waiting, you may do the following without further approval (Michael said "obvious simple work is fine; wait for me before anything meaningful"):

- Fix obvious stale pointers in `backlog/` and `docs/`.
- Normalize whitespace, broken links, or outdated file references in docs you already read.
- Convert a single uncontroversial `TODO.md` line into a `backlog/*.md` stub (do not delete the TODO entry; link it).

Do not touch source, tests, scripts, CI, or perf baselines before approval.

## Phase 3 — Execute

When the user approves:

**Solo path** — work directly, or delegate individual concerns via one-shot `Agent` calls (`Explore` for research, `code-simplifier` for targeted cleanup, `Plan` for design sketches). Keep the main thread orchestrating.

**Team path** — when parallel work by multiple teammates is the right shape:

1. `TeamCreate` with a descriptive `team_name` and short `description`.
2. Create one task per teammate concern via `TaskCreate`. Make file/module ownership explicit so branches do not conflict.
3. Spawn each teammate via `Agent` with `team_name`, a human-readable `name` (e.g. `focus`, `selection`, `reviewer`), and a `subagent_type` matched to the tools they need. For code-producing teammates use `isolation: "worktree"` so work lands on its own branch.
4. `TaskUpdate` to set each task's `owner`.
5. Review teammate PRs as they land. Do not merge without evidence. Use the `code-review` skill or `/code-review` before requesting review on your own PRs.
6. When the unit is complete, `SendMessage {"type": "shutdown_request"}` to each teammate, then `TeamDelete`.

Execution guardrails:

- Performance-sensitive changes run through `workspaces-performance-system`. Use `./scripts/perf-runner.sh` + `./scripts/perf-compare.py` with scenario ids from `config/performance/contract.json`. Never invent thresholds.
- Every PR carries uploaded evidence via `./scripts/evidence.sh --pr <N> --name <slug>` (see `CLAUDE.md` → "Evidence-Driven Development"). A PR may ship without evidence only when genuinely trivial, and the PR body must say so explicitly.
- Use `wt.sh` or `git worktree` for branch work. Do not commit in the main working directory.
- Prefer the mise tasks in `web/.mise.toml` (`mise -C web run web:check`, `web:dev`, `web:e2e`, `web:evidence`) over raw `pnpm` chains.

## Phase 4 — Ship and reflect

After the unit lands (or is handed off for review):

1. Invoke the `reflect` skill on the session trajectory. Separate findings into **product** vs. **process**.
2. **Product learnings** — append to `backlog/ROADMAP.md#Learnings` if material; otherwise a focused `backlog/*.md` item.
3. **Process learnings** cascade in this order:
   1. Update this command (`.claude/commands/improve-codebase.md`) when the learning is about how we run the loop.
   2. Update an existing skill (`.agents/skills/*`, `.claude/skills/*`, `~/.claude/skills/*`) when it belongs to a domain we already cover.
   3. Create a new skill when the learning is durable, domain-specific, and not yet covered.
   4. Only if none of the above fit, write an open-ended proposal to `backlog/*.md`.
4. If priorities shifted, reorder `backlog/ROADMAP.md` and note why.
5. Capture session state with `chronicle` so the next `/improve-codebase continue` has what it needs.

## Phase 5 — Continue or pause

Pause and return control to the user on any of these triggers:

- A quick win grew into a structural or cross-cutting change.
- More than 3 teammate PRs are open awaiting the user's review.
- Evidence is blocked and resolving it requires a human judgment call.
- Context-window usage crossed ~70% and the current unit has not shipped.
- New information meaningfully changes ROADMAP priority order.
- The user has been absent long enough that the next decision should wait for them.

Otherwise, loop to Phase 2 with the updated ground state.

## Never

- Never start code-meaningful work before the hypothesis is approved.
- Never open a PR without uploaded evidence, except a genuinely trivial PR that says so in the body.
- Never cross focus areas in a single session unless the user explicitly asks.
- Never invent perf scenarios or thresholds outside `config/performance/contract.json`.
- Never merge teammate work without reviewing it yourself.
- Never commit in the main working directory.
- Never leave a spawned team running after the unit completes — shut down, then `TeamDelete`.

## Clarifying questions

If the arg + ROADMAP + recent activity leave the next unit genuinely ambiguous, the first message back may be up to three short clarifying questions instead of a full hypothesis. After answers, proceed with Phase 2.

---

Now begin Phase 1. This should be fun.
