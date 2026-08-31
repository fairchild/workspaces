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

- **`dev`** — the owner is changing it. Minted by the owner's first commit after a release.
- **`next`** — the owner is validating it, and only fixing what validation finds. Stabilization commits land here directly.
- **`stable`** — the owner has decided it is good. The bit is flipped on a tip already in daily use.

> "I only live on stable until I make my first commit, which mints a new dev I want to easily pivot onto."
> — owner, 2026-08-30

> "I'm always by definition the first person on stable."
> — owner, 2026-08-30

The invariant these labels exist to protect is in the title. Because `stable` is flipped onto a tip the owner has been running as `next`, released code is never code nobody has used. There is no separate release candidate to validate, no staging environment standing in for real use, and no test suite asked to substitute for the judgment call — the criterion is that the owner used it and decided.

## Why one line rather than three branches

The obvious reading of a Debian-style suite model is three long-lived branches with content flowing between them. That shape was considered and rejected: it buys parallel channels this project has no user for, and charges for them in cherry-picks, divergence, and a merge every promotion.

With one line, `stable` is an ancestor of `next` is an ancestor of `dev` by construction. Promotion is `git branch -f next dev`, and its correctness is checkable rather than reviewable:

```sh
git merge-base --is-ancestor stable next   # holds, or the model is broken
```

The single line also removes the state problem that three parallel channels create. Three running installs would contend for one bundle id, one `~/Library/Application Support/com.cloudcompute.workspaces`, one SwiftData store, and one `tmux -L workspaces` server — and SwiftData migrations are forward-only in practice, so a channel that migrated the store could not be rolled back to. None of that arises when only one tip is ever live.

**The cost, named:** two competing approaches to the same problem cannot both be `dev`. That case needs an ordinary branch and has no label in this scheme. It is out of scope here rather than covered badly.

## What actually gets exercised

The owner's stated reason for the model is that it keeps the pivot path healthy, and the mechanism is worth being precise about, because promotion is not what exercises it.

Promotion is a ref move and costs nothing. What costs something is **commit-and-run**: every commit means a rebuild, and running the change means standing that build up and carrying live sessions onto it. That happens many times a day, on the critical path of ordinary work, which is the only arrangement this project has found that keeps a lane from rotting quietly.

The evidence for that claim is the record of lanes that sat off the critical path: `agent-stall-sweep.sh` never once fired from cron; `factory-revise` was five-for-five `startup_failure` with zero jobs created; the `Pi Review` gate in a sibling repo had not run since the day it was added. Each stayed broken because nothing anyone did daily depended on it. A pivot performed on every commit announces its own failure the first time it breaks.

**Consequence for cost:** at roughly one pivot per commit, build time is the binding constraint. A ten-minute rebuild makes the model unlivable, so minting a `dev` has to mean swapping which build is live rather than producing one from scratch.

## Going back is the operation that will be performed most

Most `dev` tips will not be promoted. The owner will try something, decide against it, and want to be back on `stable` — and by then the running store may have migrated forward past what `stable`'s schema expects. Forward is easy; backward is the move that will actually be needed, and nothing supports it today.

**Take a copy-on-write clone of the support directory and store at each promotion, labelled with the ref.** On APFS `cp -c` makes this close to free. Returning to `stable` then restores a commit and a known-good state together, and abandoning a `dev` is an `rm` rather than a migration.

## The flip to stable is gated on having run the tip

Because `next` accepts stabilization commits, every merge into it resets the validation clock. Merging a fix into `next` and flipping to `stable` in the same sitting sends that fix out unrun, which defeats the one invariant the scheme exists for — and it will happen on a day when the fix looks obvious.

The gate is checkable rather than advisory: **compare the tip SHA against the SHA of the build currently live, and refuse the flip when they differ.**

**Prerequisite, unmet at time of writing:** the running app must report its commit SHA. A version string alone cannot distinguish "rebuilt at the same version" from "rebuilt three commits later," and the gate degrades to a reminder. Confirm the build stamps a SHA before relying on this.

## Framing this sits inside, not decided here

The owner's larger direction is WorkSpaces as an outer perimeter — agents as processes, sandboxes as shells. Under that frame these three labels are versions of one kernel and the pivot is a reboot that restores running processes. That framing motivates the shape above and is deliberately not decided by this record; it needs its own, and its first prerequisite is a process table generated from the world rather than a hand-kept expected-set.
