# WorkSpaces — Product Overview

## Problem Statement

Developers using terminal-based coding agents (Claude Code, Aider, Codex CLI, Copilot CLI) face friction when managing concurrent work:

- **Context pollution**: Working on multiple features in the same repo leads to mixed changes
- **Setup repetition**: Each new session requires re-running install scripts, setting up env files
- **No isolation**: A broken experiment can pollute the main working copy
- **Terminal juggling**: Multiple terminal windows/tabs without clear organization

## Solution Summary

**WorkSpaces** is a Mac-native app for terminal-first AI coding with fast context switching. It discovers local repositories in `~/code`, restores the last surface you were using, opens repo overviews for navigation and launch actions, and lets you spin up isolated workspace copies when needed.

Think of it as **a terminal session manager for your code portfolio, with workspace isolation when you need it**.

## Core Capabilities

- **Launch Restoration**: Reopens the last active repo overview, workspace terminal, or web view
- **Repository Discovery**: Auto-hydrates repositories from `~/code` (non-recursive), with manual add/remove
- **Repo Overview Launcher**: Clicking a repo opens an overview with workspace and web-view actions
- **Persistent Terminal Sessions**: Repo and workspace terminals resume instead of restarting from scratch
- **Scoped Web Views**: Global, repo-owned, and workspace-owned web views live alongside terminal contexts
- **Workspace Creation**: Create isolated workspace copies per repo
- **Inline Workspace Progress**: Repo rows show coarse creation progress while a workspace copy/setup is in flight
- **Lifecycle Hooks**: `setup.sh` runs after creation, `archive.sh` runs on close
- **Embedded Terminal**: GhosttyKit (`libghostty`) terminal as the primary interface
- **Two-Pane Split Control**: Ghostty split actions can create, focus, resize, and equalize the current two-pane stack
- **Ghostty-First Shortcut Routing**: Terminal keybindings should default to Ghostty behavior; app-level shortcuts are for non-overlapping chrome actions
- **File/Changes Pane**: Collapsible right pane showing file tree and git status
- **Configurable Location**: Choose where workspaces are stored (default: `~/workspaces`)

## Sidebar Structure

The sidebar is organized around **Repositories** and **Web**. Repo rows open repo overviews; expanded repos reveal repo web views first, then workspaces:

```
┌──────────────────┐
│ [repo] my-api     │  ← Click opens repo overview
│   🌐 docs         │  ← Repo-owned web view
│   > feature-auth  │  ← Workspace terminal
│ [repo] frontend   │
│ [repo] services   │
│   🌐 changelog    │
│   > release-prep  │
├──────────────────┤
│ Web              │  ← Global web views live here
│   🌐 GitHub      │
└──────────────────┘
```

**Key interactions:**
- Click repo row → open the repo overview
- Click repo disclosure/expansion → reveal or hide repo-owned web views and workspaces
- Click workspace row → open or resume the persistent terminal session for that workspace and update right pane context
- Click web row → open the embedded web view for that source
- Click `+` or `New Workspace` on a repo → open the workspace sheet and keep that repo expanded while creation progress is shown inline
- Use the repository sort menu to switch between `Alphabetical` and stable `Last Accessed` ordering
- Click `⋯` on repo row → menu: Reveal in Finder, Remove
- Click `⋯` on workspace row → menu: Delete, Reveal in Finder

## Target Users

### Primary: AI-Augmented Developer
Developers who regularly use terminal-based coding agents (Claude Code, Aider, Codex CLI, or similar). They:
- Work on multiple features/experiments concurrently
- Value clean separation between work streams
- Prefer terminal-based workflows over heavy IDEs
- Want quick setup without manual repetition

## Design Principles

1. **Terminal-First**: The embedded terminal IS the experience. This is not a code editor — use your preferred external editor alongside.

2. **Ghostty-First Input Model**: WorkSpaces wraps a fully functional embedded Ghostty experience. Shortcut handling defaults to Ghostty unless a shortcut is explicitly reserved for app chrome.

3. **Native Mac Feel**: SwiftUI + AppKit patterns. Three-column layout like Finder/Mail. Keyboard shortcuts that feel familiar.

4. **Minimal Wrapper Chrome**: The app adds portfolio/session management and observability around the terminal without redefining terminal semantics.

5. **Non-Destructive**: Source repos are never modified. Workspaces are copies. Deleting a workspace doesn't touch the original.

6. **Offline-First**: Works without internet. Git remotes are optional. All operations are local.

7. **Minimal Chrome**: The terminal gets maximum screen real estate. Right pane collapses. Sidebar can hide.

## Shortcut Routing Policy (Product Requirement)

- Default route: deliver terminal shortcuts to embedded Ghostty.
- App route: only non-overlapping app chrome controls (for example `Cmd+B` sidebar toggle).
- Conflict handling: if both app and Ghostty claim a shortcut, expose an explicit user override so the user chooses the route.
- Future settings requirement: per-shortcut routing control (`App` vs `Ghostty`) in preferences.
- Implementation guardrail: avoid one-off per-key hardcoding in terminal event handlers; route by policy and binding detection.
- Current split contract: Ghostty `new_split`, `goto_split`, `resize_split`, and `equalize_splits` actions map onto the app's current two-pane split model; orthogonal resize directions remain explicit no-ops with logging.

## What This Is NOT

- **Not an IDE**: No syntax highlighting, code navigation, or LSP
- **Not VM-based yet**: Host-local isolation (filesystem copy) is the default. VM-backed workspaces via macOS 26 Virtualization.framework are the next planned phase
- **Not a git client**: Basic status display only; use terminal for git operations
- **Not multi-platform**: Mac-only, uses macOS-specific frameworks
