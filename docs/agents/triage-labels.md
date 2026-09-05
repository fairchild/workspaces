# Triage Labels

This repo uses composable labels instead of namespaced lifecycle labels. Labels answer one of four questions:

- **Lane**: who owns the work?
- **State**: what should happen next?
- **Dimension**: what topic or surface is this about?
- **Gate**: what special approval or intervention is required?

Do not create duplicate labels that combine these meanings. Prefer adding the right lane plus the right state.

## Lane Labels

| Label | Meaning |
| --- | --- |
| `agent` | Work is meant for the agent execution lane. April, Plat, Peter, and the dashboard treat this as agent-owned work. |
| `human` | Work is explicitly owned by a human. Use this for work that should not be picked up by the scheduled agent pipeline. |

The default for planned work is agent-driven. Peter-created execution issues should carry both `agent` and `task`.

## Author Labels

Most agent work in this repo still pushes under the owner's own GitHub account (`fairchild`), so a PR's author and assignee mostly tell you nothing about which agent produced it — and almost every PR is agent-authored. `author:<slug>` labels restore that attribution and make it filterable (`gh pr list --label author:<slug>`). This is now only *mostly* true: the GitHub-Actions Factory lanes push as `april-clearwater[bot]`/`workspace-agents[bot]`, and CLI-dispatched implementation workers (any harness) can opt into pushing as `workspaces-factory[bot]` (`FACTORY_WORKER_IDENTITY=app`, issue #1180, `docs/development/github-app-identities.md`) so the owner can formally approve the PR — but even then, `author:<slug>` is still the only thing that tells you *which agent*, since `workspaces-factory[bot]` is shared across every opted-in worker.

Rules:

- **Every agent-authored PR carries exactly one `author:<slug>` label** identifying its author, applied at PR creation. Human-authored PRs carry none.
- **Review no longer depends on it.** Counterpart review used to require exactly one `author:*` label and skip silently without one, which meant a PR nobody labelled got no review and nothing said so. Review is now the default for any pull request whose head branch is on this repository; the label decides only *which* reviewer, and only for `author:april` and `author:plat`, where it keeps a persona off its own work. Attribution is still the reason to apply it.
- **Slug = the agent's stable identity, lowercase kebab-case.** Use the persona when acting as one (`author:april`, `author:plat`, `author:carl`, `author:fable-orchestrator`); otherwise the harness (`author:claude-code`, `author:codex`). Keep it stable across sessions — it's a workstream identity, not a per-session id (session/thread ids belong in the claim comment's `claimer=<harness>:<stable-id>`, and the model belongs in the commit `Co-Authored-By` trailer).
- **Create the label if it's new:** `gh label create "author:<slug>" --color BFD4F2 --description "PRs authored by the <slug> agent"`. Reuse an existing `author:*` label rather than minting a near-duplicate.
- This is an **authorship** label — a distinct axis from lane/state/dimension/gate (none of those answer "which agent wrote this"). It is **not** a revival of the retired `agent:*` ownership labels (see § "Live Label Migration"): `author:claude-code` says who *wrote* a PR, orthogonal to the `agent`/`human` lane that says who *owns* the work. A PR can be `author:claude-code` while its issue sits in the `agent` lane.

Not CI-enforced, and no longer load-bearing: a missing label costs attribution, not review.

## State Labels

| Label | Meaning |
| --- | --- |
| `needs-triage` | Maintainer needs to evaluate the issue. |
| `task` | Planned work item. Combine with `agent` for agent pipeline work. |
| `ready` | Ready for the owning lane to act. `agent` + `ready` means an agent may claim it. `human` + `ready` means a human may pick it up. |
| `claimed` | Actively owned and in progress. For agent work, claim comments and assignees identify which agent owns it. |
| `review` | A PR exists and is awaiting review. |
| `mergeable` | Additive review signal: an agent reviewed and approved the linked PR; owner merge is now appropriate. |
| `blocked` | Progress is blocked by a dependency that should be resolved before work continues. |

`needs-info` and `wontfix` were deleted in the 2026-08-02 label hygiene sweep (#1159) as never-applied. Waiting on the reporter for missing information is no longer label-tracked — leave a comment and keep the issue in `needs-triage`. Closing as not planned uses GitHub's native "not planned" issue-close reason instead of a label.

Exactly one of `ready`, `claimed`, and `review` should be present on an active `agent` + `task` issue. `mergeable` may stack with `review`.

## Human Intervention

`human` and `needs-human` are intentionally different:

- `human` is a lane label. It means a human owns the work.
- `needs-human` is a gate label. It means the current lane needs human intervention before continuing.

Use `agent` + `needs-human` when the work remains agent-owned but needs a decision, credential, manual approval, or merge call. Remove `needs-human` once the intervention is resolved.

Use `human` when the work itself should be done by a person.

`owner-action` is the machine-written counterpart. A person applies
`needs-human` to say the lane needs a human; the factory applies `owner-action`
when it has determined, from the PR's own state, that the owner is the blocking
party — and it withdraws it once no reviewer is blocking any more. The two are
kept apart on purpose: the factory never touches `needs-human`, and it removes
only an `owner-action` it applied itself, so a hand-applied one stands. Treat
that as a courtesy rather than a guarantee: label events carry no conditional
write, so a label applied by hand between the factory's provenance read and its
delete would still be removed. If you want to say "a human is needed", say it
with `needs-human`, which the factory never touches at all. See
`scripts/factory-review-response.py`.

The marker is applied when the factory escalates and withdrawn when a trusted
approval or dismissal leaves no reviewer blocking. Both are events, so it is
only as current as the lane's last run: turning `FACTORY_REVIEW_RESPONSE_ENABLED`
off between an escalation and its resolution leaves the marker up, and switching
back on does not replay what was missed. A marker on a closed or merged PR is
also left where it is — the Digest lists open, non-draft PRs only.

## Gate Labels

Gate labels are not ownership or topic labels. They authorize or block a specific automation path.

| Label | Meaning |
| --- | --- |
| `needs-human` | The current lane needs human intervention before continuing. May be used with either `agent` or `human`. Applied by people; the factory never applies or removes it. |
| `owner-action` | The factory determined the owner is the blocking party and said so in a comment naming the gesture. Machine-managed: applied by the review-response lane, withdrawn by it once no reviewer is blocking. Surfaced as "Waiting on you" in the Factory Digest. |
| `safe-to-run-agent` | Maintainer approval for the GitHub Actions mention executor to run against a public issue or PR request. The executor consumes and clears this gate through its own workflow. |
| `safe-to-review-fork` | Admits a fork pull request into the counterpart-review lane. Same-repository heads are reviewed by default; a fork is not, because review reads the diff and writes under a reviewer app's token. Persistent — unlike `safe-to-run-agent` it is not consumed, so review survives later pushes to the fork. |
| `skip-review` | Suppresses counterpart review on a pull request that does not want one. |
| `privileged-agent-patch` | Break-glass approval for an agent patch to touch privileged repo-control, auth/token/sandbox, release/signing, or infra-secret paths. |

Do not use gate labels as backlog categories. Remove them when the gate has been consumed or the intervention is no longer needed.

## Backlog Hygiene Labels

These two labels keep the open backlog actionable without deleting history. They are orthogonal to lane/state/dimension and may stack with anything.

| Label | Meaning |
| --- | --- |
| `idea` | Speculative or unvalidated parking lot — a direction that *might* never be built. The honest home for "nice someday" enhancements so they stop reading as committed work. Supersedes the older `future` label for new triage. |
| `stale` | Inactive or superseded — a candidate for closing or deleting on the next maintainer review. Use for detailed-but-unbuilt specs whose direction is now in question, dead one-offs, and work overtaken by what shipped. Tag rather than close so a human makes the final delete call. |

`idea` keeps a maybe alive without implying commitment; `stale` flags work for removal without unilaterally erasing it. Neither gates the agent pipeline — an `agent` + `task` issue should not also carry `idea`/`stale` (move it out of the lane first).

## Matt Pocock Triage Mapping

| Label in mattpocock/skills | Label in this repo | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate the issue. |
| `needs-info` | *(no label — comment on the issue)* | Waiting on the reporter for more information; not label-tracked since the 2026-08-02 sweep removed the unused `needs-info` label. |
| `ready-for-agent` | `agent` + `ready` | Fully specified, approved, unblocked, and available for an AFK agent to claim. |
| `ready-for-human` | `human` + `ready` | Ready for a human to implement, review, or operate. |
| `wontfix` | *(no label — close as "not planned")* | Will not be actioned; use GitHub's native "not planned" issue-close reason since the 2026-08-02 sweep removed the unused `wontfix` label. |

## Dimension Labels

Dimension labels are topical and should stay separate from triage state. Apply them from repository label history so PR history can be browsed by topic.

Examples: `security`, `quality`, `devEx`, `documentation`, `enhancement`, `bug`, `area: ui`, `area: isolation`, `area: distribution`, `area: platform`, `web`.

Do not replace dimension labels with lifecycle labels. A PR or issue can be `agent` + `ready` + `security`, where `agent` and `ready` drive execution and `security` preserves topical history.

## GitHub Actions Agents

April, Plat, and Peter are label-driven:

- Peter creates planned issues with `agent` + `task`.
- The execution-state sync promotes approved, unblocked `agent` + `task` issues to `ready`, `claimed`, or `review`.
- The lifecycle health check enforces one active phase among `ready`, `claimed`, and `review` for open `agent` + `task` issues.
- The web dashboard fetches pipeline columns by `agent` plus the state label.

See `docs/development/agent-team.md` for the full agent lifecycle.

## Live Label Migration (historical)

The repository no longer uses `agent:*` labels as the canonical model; that one-shot migration is complete and `scripts/migrate-agent-labels.py` has been removed.
