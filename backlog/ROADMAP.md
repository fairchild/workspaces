---
status: in-progress
category: plan
---

# Workspaces Roadmap

## What it's for

A dependable Mac-native control surface for terminal-based coding agents: pick
the right repo or workspace quickly, keep long-lived terminal context intact,
attach the minimum useful chrome around that terminal. Remote runtimes,
activity feeds, and web surfaces earn their place by making that loop more
reliable, and terminal-first is the promise they answer to.

## The Bet

The goal is that this becomes my preferred daily driver — the app I reach for
by choice, for real work, not the one I tolerate because I wrote it.

The bet is that strong quality controls and consistent patterns, coupled with
automated development, let me dial it in to exactly the app I want without
compromise. Quality investment usually reads as a tax on shaping a thing. Here
it should be the opposite: automated development ought to make refinement
cheap enough that I keep doing it. If that's wrong, I'll see it as PRs merging
steadily while the app stops moving toward what I actually want. It works when
I stop noticing the app: pick context, get a terminal, work.

The bet is on one user. I expect that taking that seriously leaves high-quality
reusable parts along the way — libraries, packages, a good experience — and if
I like it, some other cohort likely would; Folio, the conversation experience,
is already one of them: an installable package with MFWiki as its first outside
consumer.

## The Surfaces

**Desktop.** The center of the product: a terminal-first window over a
recursive tile tree, with repo overview and Ghostty underneath. Work here
protects the layout model, terminal context, and the local state history
continuity depends on. Restoring sessions on launch is still a default-off
experiment, so continuity across relaunch remains a goal the foundations
support.

**Web.** `web-next` ships at folio.cloudcompute.com, embedded in the desktop
app; the earlier `web/` dashboard is in maintenance mode and still carries live
GitHub webhook ingestion. Web work is judged by whether it makes the desktop
loop more continuous — session continuity, cost visibility, calm. Folio's
extraction is judged separately, on whether an outside consumer can install it
and build against it.

## How work gets made

Most code arrives through the factory, the label-driven pipeline that turns
issues I release into reviewed PRs — which is why the bet's failure condition
names machinery: the pipeline can stay green and productive while the product
drifts. App identities separate worker and reviewer actions, and per-run
telemetry measures cost and intervention, so how much authority to delegate
becomes answerable from evidence. Merge authority is mine — auto-merge is
specified and disabled, the main-merge ruleset requires one approving review —
and widens only as measured reviewer agreement accumulates; privileged paths
stay owner-merged. Details in `docs/development/agent-factory-v2-plan.md`.

## Promotion

Work is promoted through GitHub milestones when it strengthens the core loop
and has an explicit verification path, and each lane — desktop, web,
automation — runs one active milestone at a time unless the milestone
description records an independence argument. Evidence gates all of it:
changes cross desktop, web, and sandboxed runtimes, so captured behavior and
recurring performance measurement come before shipping. Regression risk is
cheapest to reduce right before a surface grows, so structural and dependency
debt gets paid ahead of breadth, and automation earns its expansion — activity
and notifications should reconnect and catch up reliably before they get more
entrypoints, which they do not yet (#547).

`idea` marks speculative directions that might never be built; actionable work
uses the normal lane and state labels whether or not it has a milestone yet.
Current focus reads off the
[open milestones](https://github.com/fairchild/workspaces/milestones), and the
milestone operating contract lives in `docs/agents/issue-tracker.md`. Anything
here that would need updating more than a few times a year belongs in GitHub
or a decision doc instead.
