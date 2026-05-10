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

## State Labels

| Label | Meaning |
| --- | --- |
| `needs-triage` | Maintainer needs to evaluate the issue. |
| `needs-info` | Waiting on the reporter for specific missing information. Prefer this over the generic GitHub `question` label. |
| `task` | Planned work item. Combine with `agent` for agent pipeline work. |
| `ready` | Ready for the owning lane to act. `agent` + `ready` means an agent may claim it. `human` + `ready` means a human may pick it up. |
| `claimed` | Actively owned and in progress. For agent work, claim comments and assignees identify which agent owns it. |
| `review` | A PR exists and is awaiting review. |
| `mergeable` | Additive review signal: an agent reviewed and approved the linked PR; owner merge is now appropriate. |
| `blocked` | Progress is blocked by a dependency that should be resolved before work continues. |
| `wontfix` | Closed or closing as not planned. |

Exactly one of `ready`, `claimed`, and `review` should be present on an active `agent` + `task` issue. `mergeable` may stack with `review`.

## Human Intervention

`human` and `needs-human` are intentionally different:

- `human` is a lane label. It means a human owns the work.
- `needs-human` is a gate label. It means the current lane needs human intervention before continuing.

Use `agent` + `needs-human` when the work remains agent-owned but needs a decision, credential, manual approval, or merge call. Remove `needs-human` once the intervention is resolved.

Use `human` when the work itself should be done by a person.

## Gate Labels

Gate labels are not ownership or topic labels. They authorize or block a specific automation path.

| Label | Meaning |
| --- | --- |
| `needs-human` | The current lane needs human intervention before continuing. May be used with either `agent` or `human`. |
| `safe-to-run-agent` | Maintainer approval for the GitHub Actions mention executor to run against a public issue or PR request. The executor consumes and clears this gate through its own workflow. |
| `privileged-agent-patch` | Break-glass approval for an agent patch to touch privileged repo-control, auth/token/sandbox, release/signing, or infra-secret paths. |

Do not use gate labels as backlog categories. Remove them when the gate has been consumed or the intervention is no longer needed.

## Matt Pocock Triage Mapping

| Label in mattpocock/skills | Label in this repo | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate the issue. |
| `needs-info` | `needs-info` | Waiting on the reporter for more information. |
| `ready-for-agent` | `agent` + `ready` | Fully specified, approved, unblocked, and available for an AFK agent to claim. |
| `ready-for-human` | `human` + `ready` | Ready for a human to implement, review, or operate. |
| `wontfix` | `wontfix` | Will not be actioned. |

## Dimension Labels

Dimension labels are topical and should stay separate from triage state. The managed PR reviewer uses repository label history to apply these labels so PR history can be browsed by topic.

Examples: `security`, `quality`, `devEx`, `documentation`, `enhancement`, `bug`, `area: ui`, `area: isolation`, `area: distribution`, `area: platform`, `web`.

Do not replace dimension labels with lifecycle labels. A PR or issue can be `agent` + `ready` + `security`, where `agent` and `ready` drive execution and `security` preserves topical history.

## GitHub Actions Agents

April, Plat, and Peter are label-driven:

- Peter creates planned issues with `agent` + `task`.
- The execution-state sync promotes approved, unblocked `agent` + `task` issues to `ready`, `claimed`, or `review`.
- The lifecycle health check enforces one active phase among `ready`, `claimed`, and `review` for open `agent` + `task` issues.
- The web dashboard fetches pipeline columns by `agent` plus the state label.

See `docs/development/agent-team.md` for the full agent lifecycle.

## Live Label Migration

The repository no longer uses `agent:*` labels as the canonical model. After this code is on the default branch, migrate GitHub issue labels with:

```bash
uv run --script scripts/migrate-agent-labels.py
uv run --script scripts/migrate-agent-labels.py --apply
uv run --script scripts/migrate-agent-labels.py --apply --delete-legacy
```

The script is dry-run by default. Do not delete legacy labels until the dry run shows the expected issue updates.
