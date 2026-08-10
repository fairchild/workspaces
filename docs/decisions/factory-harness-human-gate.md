---
status: decided
date: 2026-08-09
decision: factory-harness-human-gate
related:
  - docs/decisions/factory-label-control-plane.md
  - docs/development/github-app-identities.md
  - docs/development/factory-current-state.md
---

# The Factory cannot modify its own harness

## Decision

**The `workspaces-factory` GitHub App does not have the `workflows` permission, and will not be granted it.** Its manifest (`config/github/apps/workspaces-factory.manifest.json`) carries `contents:write`, `pull_requests:write`, `issues:write`, `metadata:read`, and nothing more. GitHub refuses any push from that identity that touches `.github/workflows/*.yml`, so a bot-authored PR cannot contain a workflow-file change at all.

> "I think it's good that me human has to be involved in that"
> — owner, 2026-08-08

This is not a scope gap awaiting closure. It is the enforcement mechanism for the never-builds-itself invariant: the system that ships changes does not change the rules it ships under.

## Why a permission boundary rather than a policy

The owner account is agent-operated. Any control expressible as "the owner approves on GitHub" is therefore satisfiable by an agent — approvals, label flips, merges, and comments all run under the owner's credentials on a routine day. The permission gap is one of the few gates in this repo that genuinely requires the human, because it fails at the wire: the push is refused by GitHub before any script, gate, or reviewer is consulted.

A written policy saying "agents don't edit workflows" is a policy an agent can violate by forgetting. This one an agent cannot reach.

## The operating model

Proven live 2026-08-08/09 on [#1280](https://github.com/fairchild/workspaces/pull/1280) and [#1244](https://github.com/fairchild/workspaces/pull/1244), both of which touch `.github/workflows/`.

1. **A bot-authored PR never contains workflow changes.** There is no partial state to police — the push fails.

2. **Workflow-touching work commits as the bot and pushes over ambient owner credentials.** The commits carry `workspaces-factory[bot]` authorship; the PR renders as `fairchild`-authored. That split is the useful part: GitHub blocks a PR author from approving their own PR, so neither the orchestrator nor the author account can supply an approval. The authorization has to come from outside the machine.

3. **The PR carries `needs-human` and merges only on the owner's explicit approval, recorded as a PR comment before the merge.** #1280's record names the approval and where it was given ("Merging on Michael's explicit approval, given in chat 2026-08-08"), so the trail survives the chat it came from.

4. **A ruleset bypass granted to expedite is temporary and revoked immediately after use.** #1244 merged under a bypass Michael granted the App on 2026-08-08, recorded in a PR comment at merge time. While such a bypass stands the control is suspended, and a report covering that window should say so rather than describe the steady state. Re-verified 2026-08-10: `main-merge`'s only bypass actor is the admin repository role — no App-integration bypass remains.

## What the boundary does not cover

The gap protects the workflow-file layer and nothing else. The enforcement logic that decides whether a PR is mergeable — `scripts/factory-review.py`, `scripts/pr-readiness.py`, and `config/` — is ordinary repo content the App can push. Those are protected by review, which is a weaker control of a different kind: a reviewer has to notice, where a refused push cannot fail to.

One adjacent layer, worth not confusing with this one: the Actions-driven Implement lane declines admission on issues scoped to `.github/`, `.agents/`, or `.claude/` (`sensitive_agent_patch_paths` in `.agents/skills/cofounder-contributor/scripts/patch_policy.py`). CLI workers running under the bot identity never pass through admission at all, which is why the App permission — covering both paths — is the load-bearing control.

## Escalation

If the Factory's blast radius grows — more autonomous lanes, or less human reading per PR — the named next step is a push ruleset restricting `scripts/factory-*.py`, `scripts/pr-readiness.py`, and `config/` to the same human-in-the-loop treatment. That is a second decision on its own terms, not an automatic follow-on: it adds friction to every enforcement-script change, and the review layer is currently holding.
