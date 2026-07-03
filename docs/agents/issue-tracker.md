# Issue Tracker: GitHub

Issues and PRDs for this repo live as GitHub issues in `fairchild/workspaces`. Use the `gh` CLI for issue operations from inside this clone.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`
- **Read an issue**: `gh issue view <number> --comments --json number,title,body,state,labels,comments`
- **List issues**: `gh issue list --state open --json number,title,body,labels,assignees`
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close an issue**: `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v`; `gh` resolves `fairchild/workspaces` automatically when run inside this clone.

## When `gh` Is Unavailable

Remote/cloud sessions often lack the `gh` CLI. The same operations are available through the GitHub MCP server tools or raw REST with the session's `GH_TOKEN`/`GITHUB_TOKEN`. Issue state lives in labels and comments, not in the tool that wrote them, so any transport is equivalent.

| Operation | `gh` | GitHub MCP tool | REST |
|---|---|---|---|
| Create issue | `gh issue create` | `issue_write` (method `create`) | `POST /repos/{o}/{r}/issues` |
| Read issue | `gh issue view` | `issue_read` | `GET /repos/{o}/{r}/issues/{n}` |
| Comment | `gh issue comment` | `add_issue_comment` | `POST /repos/{o}/{r}/issues/{n}/comments` |
| Edit labels | `gh issue edit --add-label` | `issue_write` (method `update`, `labels`) | `PATCH /repos/{o}/{r}/issues/{n}` |
| Close | `gh issue close` | `issue_write` (method `update`, `state`) | `PATCH /repos/{o}/{r}/issues/{n}` |
| Milestones | `gh api repos/{o}/{r}/milestones` | not exposed — use REST | `POST /repos/{o}/{r}/milestones` |

Caveat: MCP `issue_write` label updates **replace the full label set** — read the current labels first and send the complete list, or a label you didn't mention gets dropped.

## When a Skill Says "Publish to the Issue Tracker"

Create a GitHub issue. Use the repo's normal issue labels from `docs/agents/triage-labels.md` and the agent-team conventions in `docs/development/agent-team.md` when the work is meant for the autonomous contributor pipeline.

## When a Skill Says "Fetch the Relevant Ticket"

Run `gh issue view <number> --comments`.
