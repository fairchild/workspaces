---
status: in-progress
category: plan
---

# Workspaces Roadmap

This document holds direction: what the product is for and the rules that
decide what gets worked on. Live state lives in GitHub — open milestones carry
current focus, issues carry everything else, git and merged PRs carry shipped
history, and durable rationale lives in decision docs and `docs/retros/`. If a
statement here needs updating more than a few times a year, it belongs in one
of those places instead.

## Vision

Build a dependable Mac-native control surface for terminal-based coding
agents:

- select the right repo or workspace quickly
- keep long-lived terminal context intact
- attach the minimum useful chrome around that terminal
- add remote runtimes and activity feeds only when they make that workflow more reliable

Terminal-first is the promise. Web, automation, and remote-runtime work must
strengthen the terminal workflow.

## The Three Surfaces

**Desktop app.** The product's center: a terminal-first main window over a
recursive tile tree, with repo overview, persistent sessions, and Ghostty
underneath. Desktop work protects the layout model, terminal context, and
local-continuity foundations while continuing to harden restore and
provider-specific behavior.

**Web.** `web-next` (folio.cloudcompute.com) is the active web surface,
embedded in the desktop app and run against real compute; the earlier `web/`
dashboard is in maintenance mode, though it still operates live webhook
ingestion. Most web work is judged by whether it makes the desktop loop more
continuous — session continuity, cost visibility, calm. Folio, the
conversation experience, is also a reusable package with Workspaces as its
public source and MFWiki as its first external consumer; that extraction is
judged on its own terms.

**Factory.** The label-driven pipeline turns owner-released issues into
reviewed PRs. App identities separate worker and reviewer actions, and per-run
telemetry measures cost and intervention. Merge authority expands only from
measured reviewer agreement; privileged paths remain owner-merged. The factory
is measured by throughput, intervention rate, and review effort.

## Operating Principles

The product is three surfaces that do not age at the same rate, and the
dominant risk is complexity management across them rather than feature
absence. Priority follows from that, in order:

- **Protect the core loop.** Choose context, get a ready terminal, inspect
  changes, continue without surprise. Judged by: launch and restore stay
  boring, session reuse and focus stay correct under rapid switching, the
  sidebar stays calm as capabilities grow.
- **Fix dependency debt before adding breadth.** Reducing regression risk is
  most valuable exactly when a surface is about to grow.
- **Remote runtimes are held to local's bar.** VM-backed workspaces belong in
  the product when provider identity is explicit, provisioning is
  understandable, and the architecture stays small enough to evolve safely.
- **Automation earns expansion through trust.** Activity, notifications, and
  the factory should help coordination without becoming a second product.
  Judged by: reliable reconnect and catch-up, low auth churn, entrypoints
  that reflect the actual value of what they surface.
- **Evidence gates delivery.** Changes cross desktop, web, and sandboxed
  runtimes; require captured behavior and recurring performance measurement
  before shipping.

## Promotion Model

Work is promoted through GitHub milestones when it strengthens the core loop
and has an explicit verification path. Each lane — desktop, web, automation —
runs one active milestone at a time unless an independence argument is
recorded in the milestone description. Themes under consideration stay as
tracker issues: `idea` marks speculative directions; actionable work uses the
normal lane and state labels whether or not it has a milestone yet.

Current focus reads directly off the
[open milestones](https://github.com/fairchild/workspaces/milestones); the
milestone operating contract (lane prefixes, posture headers, the legibility
gate) lives in `docs/agents/issue-tracker.md`.

When an arc completes, GitHub retains its execution state; durable rationale
and lessons go into code, tests, skills, decision docs, or `docs/retros/`.
