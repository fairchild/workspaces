We're building a team of AI agents that contribute to this codebase autonomously. April is our first agent — she picks up issues, writes code, produces evidence, and opens PRs. She runs on GitHub-hosted `macos-15`; the `lume-macos` VM lane she used to run on is retired.

Start by getting oriented:

1. Check April's last 5 runs: `gh run list --repo fairchild/workspaces --workflow "Agent: April Clearwater" --limit 5`
2. Check open PRs: `gh pr list --repo fairchild/workspaces --state open`
3. Check issues ready for agents: `gh issue list --repo fairchild/workspaces --label agent:ready`
4. Check runner health on this machine: `./scripts/runners.py` (April needs no self-hosted runner, but a dead `signing-host` still blocks releases)

Then summarize: what's working, what's stuck, what to focus on next. Fix any failures, merge what's ready, and suggest what to trigger or unblock.
