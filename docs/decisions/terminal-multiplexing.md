---
status: superseded
date: 2026-04-23
decision: tmux-primary
superseded-by: docs/decisions/tile-tree-surface-abstraction.md
supersedes:
  - backlog/done/pane-tree-tiling_plan.md
  - backlog/done/terminal-multiplexing-decision_plan.md
implements: backlog/tmux-support_plan.md
related:
  - backlog/desktop-continuity_plan.md
  - backlog/terminal-architecture-followups.md
---

# Terminal Multiplexing Model

> **Superseded by [`tile-tree-surface-abstraction.md`](tile-tree-surface-abstraction.md).**
> The `tmux-primary` decision below — deferring the native recursive pane-tree —
> was reversed in favor of a recursive **Tile Tree** with a `protocol Surface`
> seam, shipped via #625 / #633 / #645 / #658. The body is retained unchanged as
> the historical record of the 2026-04-23 reasoning.

## Decision

**Tmux is the primary multiplexing model on the desktop app. Pane-tree (a native recursive split tree in SwiftUI) is deferred indefinitely.** Pane-tree returns to the table only if (a) tmux primary fails to land cleanly during its first phase, or (b) a daily-driver use case emerges that tmux cannot serve and that desktop continuity work cannot solve separately.

Scope:

- Applies to the macOS app's main terminal panel.
- The current two-pane Ghostty-managed split stays the default until `backlog/tmux-support_plan.md` ships its first phase. There is no immediate user-visible change.
- Web/sandbox terminal is out of scope; it already uses tmux-in-sandbox for reattach (#311 → #324).

## The question that drove the decision

`backlog/done/terminal-multiplexing-decision_plan.md` framed the session around one question: *what is the daily-driver use case the chosen model must get right?* The answer landed on **continuity** — pick up where you left off after closing the laptop or switching context.

Continuity is what users actually want from a long-lived terminal-first agent workflow. Multiplexing primitives (splits, panes, windows) are a means to get there, not the end state.

## Why tmux primary

- The plumbing is already partly there. `tmux_per_session` mode is wired into terminal startup command composition; mode-change lifecycle is the gap, not greenfield code.
- Tmux brings 30 years of battle-tested behavior. We do not need to re-implement multiplexing primitives in SwiftUI.
- The build cost of pane-tree (a 5-phase reducer + invariant + view + focus + lifecycle refactor over the riskiest desktop file boundary) is high. Spending that cost on multiplexing — when continuity is the actual user need — would be misallocated.
- Reviewer friction. Pane-tree touches `ContentView.swift` and `GhosttyAppManager.swift`, which are already P0 maintainability targets. Tmux primary keeps the structural refactor optional rather than load-bearing.

## Why pane-tree did not win

Pane-tree is a coherent, well-specified plan. It loses on cost-vs-value, not on craft. The cohesive `Cmd+*` muscle-memory story (often cited as a reason to own the layout) is real, but `Ctrl+B`'s prefix model avoids direct collision with current app-owned shortcuts (confirmed in `backlog/tmux-support_plan.md`), and users who already live in tmux carry the prefix model with them.

## Why hybrid did not win

Hybrid means two split-routing implementations, mode-dependent test surfaces, and ambiguous bug ownership when something breaks. The roadmap's "do not productize both deeply at the same time" constraint is a stronger filter than the appeal of flexibility. Hybrid is the option to revisit only if tmux primary genuinely fails its first phase.

## Why we did not freeze

Freeze was tempting given the desktop P0 set is already crowded. The reason not to freeze is that the current two-pane abstraction already shows seam stress in `ContentView.swift`'s `splitSessionsByPrimaryID` / `splitLayoutsByPrimaryID` map model. Choosing tmux primary lets us *stop investing* in that abstraction rather than continue patching it. Freeze would have meant continued incremental shortcut accretion against a model we no longer believe in.

## What changes

- `backlog/tmux-support_plan.md` is promoted from awaiting-decision to active P1.
- `backlog/pane-tree-tiling_plan.md` is archived to `backlog/done/` with a pointer to this record.
- `backlog/terminal-multiplexing-decision_plan.md` is archived to `backlog/done/`; its purpose is fulfilled by this record.
- `backlog/desktop-continuity_plan.md` is added — a separate plan for the continuity gap. Tmux delivers reattach within a session; it does not deliver across-session restore on desktop. That is its own problem, and acknowledging it is what makes the decision honest.

## What does not change

- The current two-pane split UX. Until `backlog/tmux-support_plan.md` ships its mode-transition phase, users see exactly today's behavior.
- Web/sandbox tmux behavior (already shipped via #311 → #324).
- The `Cmd+D` / `Cmd+Shift+D` shortcuts. They continue to drive Ghostty splits in the default mode; tmux's `Ctrl+B` prefix layers on top in tmux mode.

## Conditions to revisit

Reopen this decision if any of the following hold:

- Tmux primary's first implementation phase ships and the result is materially worse than current two-pane for a defined daily-driver use case.
- A continuity story emerges that the desktop continuity plan cannot solve, and that story turns out to be layout-shape-dependent (i.e., the user really did want a pane-tree to restore).
- An external constraint (App Store policy, a Ghostty upstream change, a tmux dep regression) makes the tmux path materially more expensive than the current estimate.

The next checkpoint is the first phase of `backlog/tmux-support_plan.md`. If that phase lands cleanly and continuity work is in motion, this decision stays.

## Related

- `backlog/tmux-support_plan.md` — implementation
- `backlog/desktop-continuity_plan.md` — the separate continuity problem this decision exposes
- `backlog/done/pane-tree-tiling_plan.md` — archived alternative
- `backlog/done/terminal-multiplexing-decision_plan.md` — the decision-session brief that produced this record
- `backlog/terminal-architecture-followups.md` — items the implementation will touch
- PRs: #311 / #312 / #315 / #324 — tmux-in-sandbox capability + clarification
