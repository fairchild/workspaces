---
status: in-progress
category: plan
---

# Workspaces Roadmap

## What it's for

A dependable Mac-native control surface for terminal-based coding agents: pick
the right repo or workspace quickly, keep long-lived terminal context intact,
attach the minimum useful chrome around that terminal. Remote runtimes,
activity feeds, and web surfaces get added only when they make that loop more
reliable.

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
I like it, some other cohort likely would. Folio, the conversation experience,
is the first test of that: the approved next step is extracting it as a package
something outside this repo can install and build against. It is still private
to the monorepo until that lands.

## The Surfaces

**Desktop.** The center of the product: a terminal-first window over a
recursive tile tree, with repo overview and Ghostty underneath. Work here
protects the layout model, terminal context, and the local state history
continuity depends on. Restoring sessions on launch is still a default-off
experiment; graduating it is not polish, because continuity across relaunch is
what makes moving to a new build cheap enough to actually do (§ Succession).

**Web.** `web-next` ships at folio.cloudcompute.com, embedded in the desktop
app; the earlier `web/` dashboard is in maintenance mode and still carries live
GitHub webhook ingestion. Web work is judged by whether it makes the desktop
loop more continuous — session continuity, cost visibility, calm. Folio's
extraction is judged separately, on whether an outside consumer can install it
and build against it.

## Succession

I am the only user, and I build this with itself. That makes moving onto each new
version a feature rather than an operational chore. If switching costs me my
working state I will not switch, I will keep running the old build, and the new
one stops being used by the person it is for — which removes the reason to build
it this way at all.

The shape is a stair-step. Run the current build while the next one is assembled,
move onto it, confirm it holds, and let it become the environment the version
after that gets built in. Debian's unstable/testing/stable does this with built
artifacts rather than with codelines, and that distinction matters here: what this
needs is parallel *installs*, not parallel branches. One developer on a linear
main can cut a candidate from a tag and install it beside the daily driver, so a
branching model would add ceremony without answering the question.

Three things make it work, and the order is the point.

**Parallel installability** — two builds coexisting without fighting over
bundle-keyed state. Largely in place.

**Session portability** — a new install picks up the sessions the previous one
left. The terminal multiplexer already holds them; what breaks it is a launch path
that tears down sessions it did not create (#1267). This is the real work, and
everything else waits on it.

**Channels** — unstable, next, and stable as builds I select between, and run at
the same time. A channel is a build-time identity, not a launch flag: UserDefaults
domains, LaunchServices registration, dock identity, and the update feed all key
off the bundle identifier, so two installs sharing one identifier share preferences
and will update over each other whatever the environment says. Data, automation,
and multiplexer paths derive from that identity; the existing environment overrides
stay what they are, a way to isolate a single run.

Portability is what makes a channel switch uneventful. Reversing the order buys a
release process that loses working state on a schedule, which is the failure this
section exists to avoid.

Concurrency and succession pull the same knob in opposite directions. Channels
running side by side want separate session substrates so neither disturbs the
other; stepping onto a new build wants the sessions to come across. Those are
different operations rather than competing defaults: isolate by default, and move
sessions across a channel boundary by adopting them deliberately.

## How work gets made

Most code arrives through the factory — the label-driven pipeline that turns
issues I release into reviewed PRs, and the machinery that could stay green
and productive while the product drifts. App identities separate worker and
reviewer actions, and per-run
telemetry measures cost and intervention, so how much authority to delegate
becomes answerable from evidence. Merge authority is mine — auto-merge is
specified and disabled, the main-merge ruleset requires one approving review —
and widens only as measured reviewer agreement accumulates; privileged paths
stay owner-merged. Details in `docs/development/agent-factory-v2-plan.md`.

## Promotion

Work is promoted through GitHub milestones when it strengthens the core loop
and has an explicit verification path, and each lane — desktop, web,
automation — runs one active milestone at a time unless the milestone
description records an independence argument. Evidence gates all of it.
Changes cross desktop, web, and sandboxed runtimes, so captured behavior and
recurring performance measurement come before shipping. Regression risk is
cheapest to reduce right before a surface grows, so structural and dependency
debt gets paid ahead of breadth. Activity and notifications should reconnect
and catch up reliably before they get more entrypoints, which they do not
yet (#547).

`idea` marks speculative directions that might never be built; actionable work
uses the normal lane and state labels whether or not it has a milestone yet.
Current focus reads off the
[open milestones](https://github.com/fairchild/workspaces/milestones), and the
milestone operating contract lives in `docs/agents/issue-tracker.md`. Narrative
history lives in `docs/retros/` from mid-2026 on, and in git before that.
Anything here that would need updating more than a few times a year belongs in
GitHub or a decision doc instead.
