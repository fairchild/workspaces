---
status: in-progress
category: plan
---

# Workspaces Roadmap

This document holds direction: what the product is for, what order the work
happens in, and why. Live state — open issues, milestones, what shipped when —
lives in GitHub, not here. If a statement in this file needs updating more than
a few times a year, it belongs in the tracker instead.

## Vision

Build the best Mac-native control surface for terminal-based coding agents:

- select the right repo or workspace quickly
- keep long-lived terminal context intact
- attach the minimum useful chrome around that terminal
- add remote runtimes and activity feeds only when they make that workflow more reliable

Terminal-first is the promise. Everything else — web surfaces, agent
automation, remote runtimes — earns its place by serving that promise, not by
existing alongside it.

## The Three Surfaces

**Desktop app.** The product's center: a terminal-first main window over a
recursive tile tree, with repo overview, persistent sessions, and Ghostty
underneath. The layout model, session durability, and daily-driver reliability
work are complete arcs; the app is the daily driver it set out to be. The next
desktop theme is deliberately unchosen — breadth waits until something clears
the priority rule below.

**Web.** `web-next` (folio.cloudcompute.com) is the active web surface,
embedded in the desktop app and run against real compute. The earlier `web/`
dashboard is in maintenance mode and receives fixes only. Web work is judged
by whether it makes the desktop loop more continuous — session continuity,
cost visibility, and calm — rather than by web-native feature count.

**Factory.** The agent-automation pipeline authors, reviews, and merges real
changes: a label-driven control plane, App-identity reviewers and workers,
per-run cost telemetry, and merges that now require a formal approving review.
The factory is judged by delivery throughput and review drag on the other two
surfaces, never by its own surface area.

## Operating Principles

The product is three surfaces that do not age at the same rate, and the
dominant risk is complexity management across them, not feature absence. That
shapes everything below.

- Protect the core promise first: select context, get a dependable terminal,
  keep working. Work that hardens this loop outranks everything.
- Fix dependency debt before adding breadth. Reducing regression risk is most
  valuable exactly when a surface is about to grow.
- Side systems expand only after they are trustworthy enough not to drag on
  the core. An automation lane that needs manual repair is a cost, not a
  capability.
- Evidence gates delivery. Changes cross desktop, web, and sandboxed runtimes,
  so a green build is not proof; captured behavior is. Performance stays a
  measured system, not a fire drill.
- The tracker is the single source of live state. This file changes when
  direction changes.

## Product Goals

**Keep the core loop excellent.** Choose context, get a ready terminal,
inspect changes, continue without surprise. Launch and restore stay boring;
session reuse and focus stay correct under rapid switching; the sidebar stays
calm as capabilities grow.

**Make remote runtimes trustworthy.** Remote and VM-backed workspaces are part
of the direction only if they feel as dependable as local: provider identity
is explicit, provisioning is understandable, and the architecture stays small
enough to evolve safely.

**Make automation useful without noise.** Activity, notifications, and the
factory should help coordination rather than become a second product with its
own complexity tax. Reconnect behavior is reliable, auth churn stays low, and
automation entrypoints reflect the actual value of what they surface.

**Preserve evidence-driven delivery.** Verification loops matter more here
than usual. Shared-desktop validation stays non-disruptive, runtime smoke
checks stay repeatable, and refactors ship with deterministic proof.

## Now / Next / Later

**Now.** Close the repo-health arc (the last item is this document). Land the
worker-identity rollout's remaining follow-through: dogfood approval-required
merges and retire the friction they surface. Resolve the one open factory
dogfood question so its milestone can close.

**Next** — candidates, not commitments, in no order:

- web-next continuity and cost: session calm, spend visibility, and the
  subscription/billing question
- the next desktop theme, chosen against the priority rule rather than
  momentum
- an iOS companion via TestFlight, if the desktop loop's value carries to a
  second screen
- factory refinement: fewer manual interventions per merged PR, measured

**Later.** Everything else stays in the tracker as issues with the `idea`
label until it earns a milestone. An empty Later section here is the point:
this file is not a backlog.

## What This Document Is Not

No shipped-history ledger — git and closed milestones hold that. No backlog
index — the tracker holds that. No per-issue links except where a live anchor
genuinely helps. When an arc completes, its story belongs in a closing
milestone comment or a decision doc, not appended here.
