---
status: decided
date: 2026-08-30
decision: development-channels
related:
  - docs/decisions/terminal-multiplexing.md
  - docs/decisions/factory-harness-human-gate.md
---

# Stable is never code nobody has run

## Decision

**`dev`, `next` and `stable` are three labels on one line of development, naming the owner's posture toward the tip rather than three copies of the code.** They ratchet forward over the same commits; promotion is a ref move, not a merge.

- **`dev`** — the owner is changing it. Minted by the first commit after a release.
- **`next`** — the owner is validating it, and only fixing what validation finds. Stabilization commits land here directly.
- **`stable`** — the owner has decided it is good, and flips the bit on a tip already in daily use.

> "I only live on stable until I make my first commit, which mints a new dev I want to easily pivot onto."
> — owner, 2026-08-30

> "I'm always by definition the first person on stable."
> — owner, 2026-08-30

The title is a property of the mechanism rather than an aspiration: `stable` is only ever flipped onto a tip already run as `next`. Nothing stands in for that use — no separate release candidate, no staging environment, no test suite substituting for the judgment call.

## Why one line rather than three branches

The obvious reading of a Debian-style suite model is three long-lived branches with content flowing between them. It buys parallel channels this project has no user for, and charges cherry-picks, divergence, and a merge at every promotion.

With one line, `stable` is an ancestor of `next` is an ancestor of `dev` by construction, so promotion is `git branch -f next dev` and its correctness is checkable rather than reviewable:

```sh
git merge-base --is-ancestor stable next   # holds, or the model is broken
```

One line also removes the state problem three channels create. Three running installs contend for one bundle id, one `~/Library/Application Support/com.cloudcompute.workspaces`, one SwiftData store, and one `tmux -L workspaces` server — and SwiftData migrations are forward-only in practice, so a channel that migrated the store could not be rolled back to.

**The cost, named:** two competing approaches to one problem cannot both be `dev`. That case needs an ordinary branch and has no label here. Out of scope rather than covered badly.

## What actually gets exercised

Promotion is not what keeps the pivot path healthy — it is a ref move and costs nothing.

**Commit-and-run** is what costs something: every commit means a rebuild, and running the change means standing that build up and carrying live sessions onto it, many times a day, on the critical path of ordinary work.

That placement is the point. The lanes this project lost were the ones nothing daily depended on — `agent-stall-sweep.sh` never once fired from cron, `factory-revise` was five-for-five `startup_failure` with zero jobs, the `Pi Review` gate in a sibling repo had not run since the day it was added. A pivot performed on every commit announces its own failure the first time it breaks.

**Consequence:** at one pivot per commit, build time is the binding constraint. A ten-minute rebuild makes the model unlivable, so minting a `dev` has to mean swapping which build is live rather than producing one.

## Going back is the operation performed most

Most `dev` tips will not be promoted — try something, decide against it, want `stable` back — and by then the running store may have migrated past what `stable`'s schema expects. Forward is easy; backward is the move actually needed, and nothing supports it today.

**Take a copy-on-write clone of the support directory and store at each promotion, labelled with the ref.** On APFS `cp -c` makes that close to free. Returning to `stable` restores a commit and a known-good state together, and abandoning a `dev` becomes an `rm` rather than a migration.

## The flip to stable is gated on having run the tip

Because `next` accepts stabilization commits, every merge into it resets the validation clock. Merge a fix into `next`, flip to `stable` in the same sitting, and that fix ships unrun — defeating the one invariant the scheme exists for, on a day when the fix looked obvious.

The gate is checkable rather than advisory: **compare the tip SHA against the SHA of the build currently live, and refuse the flip when they differ.**

**Prerequisite, unmet at time of writing:** the running app must report its commit SHA. A version string cannot distinguish "rebuilt at the same version" from "rebuilt three commits later," and the gate degrades to a reminder. Confirm the build stamps a SHA before relying on this.

## The framing this sits inside

The owner's larger direction is WorkSpaces as an outer perimeter — agents as processes, sandboxes as shells. Under that frame these labels are versions of one kernel and the pivot is a reboot that restores running processes. That motivates the shape above and is deliberately not decided here; it needs its own record, and its first prerequisite is a process table generated from the world rather than a hand-kept expected-set.
