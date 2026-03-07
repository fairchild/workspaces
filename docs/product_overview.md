# Workspaces — Product Overview

## Problem Statement

Developers using terminal-based coding agents (Claude Code, Aider, Codex CLI, Copilot CLI) face friction when managing concurrent work:

- **Context pollution**: Working on multiple features in the same repo leads to mixed changes
- **Setup repetition**: Each new session requires re-running install scripts, setting up env files
- **No isolation**: A broken experiment can pollute the main working copy
- **Terminal juggling**: Multiple terminal windows/tabs without clear organization

## Solution Summary

**Workspaces** is a Mac-native app for terminal-first AI coding with fast context switching. It keeps a persistent host terminal portfolio, discovers local repositories in `~/code`, and lets you spin up isolated workspace copies when needed.

Think of it as **a terminal session manager for your code portfolio, with workspace isolation when you need it**.

## Core Capabilities

- **Host Portfolio Default**: App starts in `~/code` by default (`$HOME/code`, then `$HOME` fallback)
- **Repository Discovery**: Auto-hydrates repositories from `~/code` (non-recursive), with manual add/remove
- **Persistent Host Sessions**: Click repo/workspace rows to open or resume a live host terminal in that directory
- **Workspace Creation**: Create isolated workspace copies per repo
- **Inline Workspace Progress**: Repo rows show coarse creation progress while a workspace copy/setup is in flight
- **Lifecycle Hooks**: `setup.sh` runs after creation, `archive.sh` runs on close
- **Embedded Terminal**: GhosttyKit (`libghostty`) terminal as the primary interface
- **Two-Pane Split Control**: Ghostty split actions can create, focus, resize, and equalize the current two-pane stack
- **Ghostty-First Shortcut Routing**: Terminal keybindings should default to Ghostty behavior; app-level shortcuts are for non-overlapping chrome actions
- **File/Changes Pane**: Collapsible right pane showing file tree and git status
- **Configurable Location**: Choose where workspaces are stored (default: `~/workspaces`)

## Sidebar Structure

The sidebar centers on a persistent **Host Portfolio** row plus expandable repo rows that reveal their workspaces inline:

```
┌──────────────────┐
│ Host Portfolio [LIVE] │  ← One-click return to default host terminal
│                  │
│ [repo] my-api LIVE │  ← Repo rows can show live terminal badge
│   ↳ feature-auth  │  ← Workspace rows live under their repo
│   ↳ bugfix-nav    │
│ [repo] frontend   │
│ [repo] services   │
│   ↳ release-prep  │
├──────────────────┤
│ [+] Add repo     │  ← Add new repository
└──────────────────┘
```

**Key interactions:**
- Click `Host Portfolio` row → switch back to the default `~/code` host session
- Click repo row → open/resume persistent host terminal session for that repo path
- Click repo disclosure/expansion → reveal or hide workspaces nested under that repo
- Click workspace row → open/resume persistent host terminal session for that workspace path and update right pane context
- Click `+`/`New Workspace` action on a repo → opens "New Workspace" modal and keeps that repo expanded while creation progress is shown inline
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

2. **Ghostty-First Input Model**: Workspaces wraps a fully functional embedded Ghostty experience. Shortcut handling defaults to Ghostty unless a shortcut is explicitly reserved for app chrome.

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
