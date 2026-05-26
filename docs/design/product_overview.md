# Spaces Chat & Agent Dispatch

## Problem

You have a fleet of AI coding agents defined in `.agents/` directories across your repos. Today, dispatching them requires terminal access — SSH into a machine, run `kanban task start`, or trigger a GitHub workflow manually. There's no way to:

- **Talk to agents** from a browser — ask for status, request work, review output
- **Dispatch agents by name** — `@april-clearwater go fix the flaky test in #234`
- **See the conversation** — what did the agent do, what did it produce, what's it working on now
- **React to repo events conversationally** — a PR fails CI, you want to say "retry" or "fix it"

The dashboard at spaces.cloudcompute.com already shows agent cards, webhook events, and pipeline status. But it's read-only. The missing piece is a **chat interface** that turns observation into action.

## Solution

Add a chat layer to spaces.cloudcompute.com that:

1. **Receives GitHub webhook events** (already working) and surfaces them as chat-like messages
2. **Accepts user messages** with @mentions that route to specific agents or the bot itself
3. **Dispatches agent work** — creating Kanban tasks, triggering GitHub Discussions workflows, or invoking Claude directly
4. **Streams responses** back into the conversation as agents work

The Chat SDK (`@chat-adapter/github`) handles the GitHub side (mentions in Discussions/Issues trigger the bot). The web UI provides a first-party chat experience that doesn't require leaving the dashboard.

## Core Capabilities

- **Web chat panel** — persistent chat UI in the dashboard, scoped per-repo or global
- **@mention dispatch** — type `@april-clearwater`, `@peter-planner`, or another discovered agent name to route a message
- **GitHub Discussion bridge** — messages posted in the web chat can create/reply to GitHub Discussions, and vice versa
- **Agent status in chat** — when an agent is dispatched, its progress appears as chat messages (task created, PR opened, review ready)
- **Webhook events as chat context** — CI failures, PR merges, and other events appear inline so you can react to them conversationally
- **Bot responses** — the Spaces bot can answer questions about repo state, agent status, and pipeline health without dispatching a full agent

## Target Users

- **You (Michael)** — primary user, managing agents across ~15 repos from the web dashboard
- **Future collaborators** — team members who want to dispatch agents or check status without terminal access

## Design Principles

1. **Chat is the command line for agents** — if you can say it, you can dispatch it
2. **Events are messages** — webhook events, agent updates, and human messages live in the same stream
3. **Repo-scoped by default** — selecting a repo in the sidebar scopes the chat to that repo's agents and events
4. **Progressive disclosure** — read-only by default (event stream), interactive when you type
5. **GitHub is the system of record** — web chat creates GitHub Discussions/comments, not a parallel conversation silo
6. **Terminal aesthetic** — dark, monospace, industrial observatory style matching the existing dashboard
