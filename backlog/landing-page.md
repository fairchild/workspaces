---
status: pending
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# Landing Page

**Status**: backlog
**Priority**: after polish phase, before or alongside public launch

## Purpose

Public-facing page for the Workspaces project. First impression for potential users and forkers — show what the app does, let them download it, link to the repo.

## Hosting

GitHub Pages or Cloudflare Pages — single static page, no build pipeline needed.

## Page Structure

### 1. Hero

- App icon + "Workspaces" title
- Tagline: "Terminal-first workspace manager for AI coding"
- One-sentence value prop: works with any terminal-based coding agent (Claude Code, Aider, Codex CLI, or plain shell)
- **Download button** — links to `https://github.com/fairchild/workspaces/releases/latest` (DMG, macOS 14+)
- **View on GitHub** secondary link

### 2. Screenshots — Core User Stories

Each screenshot should show the full app window (three-column layout) in a realistic state. Capture with `./scripts/capture-window.sh` or manually.

| Screenshot | Shows | Maps to |
|------------|-------|---------|
| **Repo overview** | App launch or return state — sidebar with repos, repo overview, and launch actions | Story 1: First-Time Setup |
| **AI coding session** | Workspace selected, terminal-based agent running in terminal, files/changes in right pane | Story 1: terminal in use |
| **Workspace switching** | Multiple workspaces under a repo, live-session indicators in sidebar | Story 2: Switching Between Workspaces |
| **Parallel experiments** | Repo web views mixed with two+ workspaces under the same repo | Story 3: Creating Parallel Experiments |

Four screenshots is enough. Stories 4-7 (delete, settings, repo-overview return, shortcuts) are interaction-based and don't screenshot well — mention them in feature bullets instead.

### 3. Feature Bullets

Short list covering what's not shown in screenshots:

- Lifecycle hooks (`setup.sh` / `archive.sh`) for workspace automation
- Repo overview as the launch/return surface for workspace and web-view actions
- Ghostty keybindings pass through — feels like your terminal, not a wrapper
- Settings for workspace root location
- CLI for scripting (`WorkspaceManagerCLI`)

### 4. Philosophy

Brief section (3-4 lines):

- Agent-agnostic — the core is an embedded terminal with workspace chrome; any terminal-based agent works
- Built with Claude Code as the daily driver, but designed for Aider, Codex CLI, Copilot CLI, or plain shell
- Fork-friendly — no plugin API, the codebase is the API
- Pairs with [dotclaude](https://github.com/fairchild/dotclaude) for a complete Claude Code setup (one example of many possible configurations)
- Apache-2.0 licensed

### 5. Download + Fork CTA

Bottom of page:

- **Download** button (same GitHub Releases link)
- **Fork & Customize** link to repo
- macOS 14+ requirement note

## Screenshot Capture Plan

Before building the page, capture the four screenshots:

1. **Fresh launch or restored overview** — Open app with a few repos in `~/code` and land on a repo overview. Shows the current launch/navigation model.
2. **Active session** — Select a workspace, run a coding agent (or any command) in terminal. Wait for some output. Shows the app doing its job.
3. **Multiple workspaces** — Create 2-3 workspaces under one repo. Click between them so sidebar shows live indicators.
4. **Parallel experiments** — Ensure sidebar shows a repo-owned web view plus `approach-a`, `approach-b` (or similar) under the same repo.

Capture at 2x resolution for Retina. Use the app's actual dark theme — no mocking needed, real screenshots sell better.

Output to `docs/screenshots/` and commit these assets so they are published with the docs site. Keep files web-friendly (compressed, consistent dimensions).

## Tech

- Single `index.html` with inlined CSS
- Dark theme: charcoal `#1e1e2a`, mint green `#4ade80`, subtle gray `#3a3a4a`
- Responsive (looks good on mobile even though the app is macOS-only)
- App icon from `docs/assets/icon-concepts/icon-master-1024.png` as favicon

## Design Reference

- `docs/branding.md` for full color palette and design principles
- `docs/user-stories.md` for wireframes and flow context

## Open Questions

- Custom domain or `fairchild.github.io/workspaces`?
- Include a short screencast/gif alongside static screenshots?
