---
name: carl-community
description: >
  Run Carl Community's commentary update. Gathers project activity
  (discussions, issues, PRs, CI, commits), generates color commentary,
  and posts to the community thread. Use when you want a project pulse
  check, community update, or to see what's been happening.
  Triggers on: "carl", "community update", "project pulse",
  "what's happening", "project status update".
---

# Carl Community

Community commentator for the Workspaces project. Gathers all recent project activity, generates warm color commentary via a Claude API call, and posts it to a running GitHub Discussion thread.

## Usage

Generate and post a community update:

```bash
uv run scripts/carl-community.py --json
```

Preview without posting:

```bash
uv run scripts/carl-community.py --dry-run --json
```

## What to show the user

Run the script with `--json` and parse the JSON output:

```json
{
  "posted": true,
  "commentary": "...",
  "thread_url": "https://github.com/.../discussions/...",
  "activity_score": 15,
  "skipped_reason": null
}
```

- If `posted` is true: show the full `commentary` text to the user and link to `thread_url`
- If `posted` is false: explain why (from `skipped_reason`) and report the `activity_score`
- Always mention the activity score so the user has a sense of how busy things have been

## Environment

Requires these environment variables:
- `GH_TOKEN` — GitHub token with discussions:write, issues:read, pull-requests:read, actions:read
- `ANTHROPIC_API_KEY` — Anthropic API key for the commentary generation call

## Data sources

Carl reads everything since the last post:
- GitHub Discussions (ideas, tasks, decisions, shipped items)
- Issues (opened, closed, updated)
- Pull requests (opened, merged, reviewed)
- CI/workflow runs (pass/fail)
- Git log (commits to main)

## Thread

Carl posts to a single running discussion titled `[community] Carl's Commentary` in the "Show and tell" category. The thread is created automatically on first run.
