# Why this skill works the way it does

A note for the human, not the agent — the SKILL.md files carry the operating
instructions; this file carries the reasoning behind the 2026-07-09 revision,
so future-you can reconstruct why the loop is shaped like this before changing
it.

**Provenance:** the W6 arc, run 2026-07-08/09 by the Fable coordinator in
Conductor workspace `amman-v3` (Claude Code session
`b5933045-65bc-42fa-befd-67b77590b5db`), burning down milestone
[W6](https://github.com/fairchild/workspaces/milestone/19) — eight web-next
issues from the host-compute daily-driver decision
(`web-next/docs/decisions/host-compute-daily-driver.md`), shipped as PRs
#1002, #1010, #1012, #1016, #1017, #1018, #1019. The full transcript lives in
that session; the PR bodies each narrate their slice of the loop.

## The finding that rewrote the skill

This skill used to say: *skip a second codex review pass — self-review by the
implementer is low-signal; the orchestrator review substitutes.* W6 ran the
opposite experiment (at Michael's insistence: codex implements, orchestrator
reviews, AND a directed codex review on every task) and the old advice lost
decisively. The directed codex review found defects the orchestrator review
had missed on **every single task** — fifteen findings across six issues,
roughly five of them blockers that green gates would have shipped:

- **#809 (mobile polish, the smallest task):** the dismissed status handle's
  invisible 44px button stole taps from the send button's corner. The
  orchestrator review had *explicitly assessed the halos and waved them
  through*. This is also the counter-example to tiering review effort by task
  size — the smallest diff produced the only blocker.
- **#981 (host provider):** the orchestrator review caught the server's
  `ANTHROPIC_API_KEY` leaking into the child (silently flipping turns from
  subscription to API billing — the exact thing the feature existed to avoid);
  the codex review then caught a *different* blocker the orchestrator missed:
  user-level `settings.json` re-granting write tools past `--allowedTools`,
  because CLI allowlists add permissions but don't erase config. Two reviewers,
  same diff, disjoint blockers.
- **#984 (steering queue):** row-atomic-but-not-session-atomic dispatch (two
  dispatchers each claim a different message → two concurrent turns) and a
  claimed-but-unstarted crash window that no recovery path could see.

The lesson worth keeping: **review independence comes from context and
framing, not model identity.** "Codex reviewing codex" sounded like
self-review, but a fresh process reading the diff as an artifact, primed with
adversarial questions, has none of the implementer's blind spots. What's
actually low-signal is the same *session* reviewing its own still-warm work —
which is equally true of the orchestrator reviewing its own reaction commits,
which is why the directed review now runs *after* reactions, on the final tree.

## The second finding: questions are the product

Every one of those fifteen findings traced back to a directed focus area the
orchestrator wrote from its own read of the diff — "can the halo steal clicks
from a neighbor," "trace prod inertness default-off," "can two dispatchers
both pass the idle check." The generic parts of the prompts produced nearly
nothing. So the orchestrator review was quietly reframed: its chief product is
the **attack-surface map** handed to the reviewer, not its own verdict. The
question taxonomy that did the damage is preserved and meant to grow:
`../codex-review-loop/references/attack-patterns.md`.

## Why the layers stay complementary

Each layer of the W6 loop caught something every other layer missed: codex's
own mutation checks (it found its search predicate untested), the orchestrator
review (billing capture), the directed codex review (everything above), the
gates (a red suite masked by a `| tail` pipeline — hence "run gates bare"),
and CI's perf floor (a 2x home-LCP regression from a `useSearchParams` CSR
bailout that *both* reviewers read straight past — reviews read code; only
gates measure). The mechanical rules that look fussy in SKILL.md (port blocks,
explicit-path staging, fetch-before-worktree-add, quota-wall handling) each
correspond to a real incident from this arc, most of them mine.

## Cost, honestly

Directed reviews ran 75–230k codex tokens each; hardening loops added hours of
wall clock, and one codex usage-limit wall stalled the keystone for ~2.5
hours. For daily-driver infrastructure — auth, billing, concurrency — the
finding rate justified every token. The tiering rule that survived: effort
follows **blast radius**, not diff size.
