# backlog/

`CLAUDE.md` here is a symlink to this file — read one, not both.

Task state lives in GitHub Issues on **fairchild/workspaces**. The repo's open issues
*are* the backlog — there is no separation between "backlog tasks" and
"other issues." Anything open is takeable.

Use the `backlog` skill (add / take / advance / progress / cancel / fail /
rescue / retry / maintain / status) to interact. Tasks are referenced by
issue number (`take 42` or `take #42`). Verbs dispatch to `gh issue`
under the hood.

## Backend

`github-issues` — see the `backlog` skill's `references/backends/github-issues.md`.

State mapping:

| State    | open/closed | labels                  |
|----------|-------------|-------------------------|
| todo     | open        | no `doing`            |
| doing    | open        | `doing`               |
| done     | closed      | no `failed`           |
| failed   | closed      | `failed`              |

`cancel` and ordinary `done` both close the issue — discriminated by the
worklog comment and GitHub's close reason. Title is free text; the spec body
carries `priority`/`timeout`/`dependencies` as YAML frontmatter, same shape
as the maildir backends.

## Pipeline

`todo → doing → done` (intermediate stages aren't supported in v1).

## ROADMAP

Strategic counterpart at `backlog/ROADMAP.md`. See the `backlog` skill's `references/roadmap.md`.
