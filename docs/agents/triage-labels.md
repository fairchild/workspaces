# Triage Labels

The Matt Pocock skills speak in five canonical triage roles. This repo already has an agent lifecycle vocabulary, so map the canonical roles to the labels below instead of creating near-duplicates.

| Label in mattpocock/skills | Label in this repo | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate the issue. No existing repo label carries this exact meaning. |
| `needs-info` | `needs-info` | Waiting on the reporter for more information. No existing repo label carries this exact meaning. |
| `ready-for-agent` | `agent:ready` | Fully specified, approved, unblocked, and available for an AFK agent to claim. |
| `ready-for-human` | `needs-human` | Requires human implementation, review, or intervention. |
| `wontfix` | `wontfix` | Will not be actioned. |

When a skill mentions a canonical role, use the corresponding label string from this table.

## Related Agent Lifecycle Labels

These labels are part of this repo's existing agent pipeline but are not direct replacements for the five canonical triage roles:

- `agent:task` marks a planned agent-team issue.
- `agent:claimed` marks active agent ownership.
- `agent:review` marks an issue with an open PR awaiting review.
- `agent:mergeable` marks an agent-reviewed PR that is ready for owner merge.

See `docs/development/agent-team.md` for the full lifecycle.
