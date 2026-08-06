# GitHub App Identities

This repo uses separate GitHub App identities for agent work. They are intentionally not interchangeable.

| App | Bot login | Commit role | Required permissions |
|-----|-----------|-------------|----------------------|
| `april-clearwater` | `april-clearwater[bot]` | Contributor that may open PRs and push commits as April | `contents:write`, `pull_requests:write`, `metadata:read` |
| `workspace-agents` | `workspace-agents[bot]` | Contributor that may open PRs and push commits for shared agent execution | `contents:write`, `pull_requests:write`, `metadata:read` |
| `workspaces-claude-pr-reviewer` | `workspaces-claude-pr-reviewer[bot]` | Review-only app; must not push commits | `contents:read`, `pull_requests:write`, `statuses:write`, `metadata:read` |
| `workspaces-factory` | `workspaces-factory[bot]` | Contributor identity for Orca-dispatched implementation workers (issue #1180) — opt-in via `FACTORY_WORKER_IDENTITY=app`, shared across workers rather than per-agent since `author:<agent>` labels already carry attribution | `contents:write`, `pull_requests:write`, `issues:write`, `metadata:read` |

`april-clearwater` and `workspace-agents` are the GitHub-Actions-driven Factory lanes (`factory-implement.yml`, `agent-executor.yml`); `workspaces-factory` is a distinct mechanism for CLI workers dispatched outside GitHub Actions (Orca worktrees) that otherwise push and open PRs under the operator's own `gh` auth. Created and installed on `fairchild/workspaces` 2026-08-05 (App ID `4501816`; credentials at `~/.config/gh-apps/workspaces-factory/app.pem`, exported as `FACTORY_WORKER_APP_ID`/`FACTORY_WORKER_APP_KEY`). The worker tooling that mints and uses its token (manifest, `scripts/factory-worker-token.py`, `scripts/factory-worker-identity.sh`) lands via #1203 (open as of this writing, not yet merged); this PR is the end-to-end rollout proof for issue #1180 — a `workspaces-factory[bot]`-authored PR, CI triggering on the App-token push, and a formal `fairchild` approval GitHub counts.

## Mechanism

GitHub shows three related but distinct identities:

1. PR author: the GitHub App token that creates the PR.
2. Commit author: the local git `user.name` and `user.email` used before `git commit`.
3. Review author association: GitHub's relationship between the reviewer and this repository.

`contents:write` only lets an app push branches and commits. It does not by itself make the bot a contributor. Treat `CONTRIBUTOR` status as proven only after a live review reports that association; a linked bot-authored commit on an unmerged PR branch is not enough evidence.

Contributor runs set `GH_APP_SLUG` and use the approved identity table in `.agents/skills/cofounder-contributor/scripts/execution.py`. The table maps app slugs to canonical bot noreply addresses:

- `april-clearwater` uses `268297116+april-clearwater[bot]@users.noreply.github.com`
- `workspace-agents` uses `266434718+workspace-agents[bot]@users.noreply.github.com`

If a workflow sets an unknown `GH_APP_SLUG`, contributor execution fails before committing. This is deliberate: adding a commit identity is a security decision.

## Public Mentions

Use `@april-clearwater` for April in GitHub issues, PRs, and review comments. Do not use `@april`; that is a different real GitHub user and must not queue Workspaces automation.

Local persona aliases are separate from public GitHub mentions. `/become april` may stay as local operator shorthand because it does not notify or dispatch a GitHub user.

## Code Owner Gate

`.github/CODEOWNERS` lists `@fairchild` as the global code owner:

```text
* @fairchild
/.github/ @fairchild
```

Branch protection or a repository ruleset can then require:

- two approving reviews
- code owner review

With only `@fairchild` listed as code owner, one required approval must come from `fairchild`. The second approval may come from the intended contributor bot only after live GitHub evidence proves that required-review protection counts that app-bot approval.

## Repeating The Contributor Setup

To make another app a contributing bot:

1. Grant the GitHub App `contents:write`, `pull_requests:write`, and `metadata:read`.
2. Re-approve the app installation on `fairchild/workspaces`; existing installations do not receive new permissions automatically.
3. Look up the bot account ID with `gh api users/<bot-login>%5Bbot%5D --jq '{login,id}'`.
4. Add the app slug, bot login, and canonical noreply email to the approved identity table.
5. Run a disposable PR with that app token and verify the PR author and commit attribution resolve to the bot.
6. After a bot-authored commit lands in the default branch history, verify a later review from that bot reports `authorAssociation: CONTRIBUTOR`.

When seeding contributor status through a PR, merge with a merge commit. Squash or rebase merging can remove the bot-authored commit from default-branch history and invalidate the contributor evidence.

Do not repeat this process for `workspaces-claude-pr-reviewer`. That app is intentionally review-only.

## Verification Checklist

Before relying on the approval policy:

1. Confirm `@april-clearwater` queues triage and `@april` does not.
2. Confirm `april-clearwater[bot]` can open a PR as itself.
3. After `workspace-agents` receives `contents:write`, confirm it can push an attributed commit as `workspace-agents[bot]`.
4. Confirm `workspaces-claude-pr-reviewer[bot]` still lacks `contents:write` and has no commits in repo history.
5. On a disposable PR, confirm GitHub branch protection counts one app-bot approval plus one `@fairchild` code-owner approval before requiring that policy on `main`.
