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

## When a Skill Says "Publish to the Issue Tracker"

Create a GitHub issue. Use the repo's normal issue labels from `docs/agents/triage-labels.md` and the agent-team conventions in `docs/development/agent-team.md` when the work is meant for the autonomous contributor pipeline.

## When a Skill Says "Fetch the Relevant Ticket"

Run `gh issue view <number> --comments`.
