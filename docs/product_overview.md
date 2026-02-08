# Workspaces — Product Overview

## Problem Statement

Developers using AI coding assistants (Claude Code, Cursor, Copilot) face friction when managing concurrent work:

- **Context pollution**: Working on multiple features in the same repo leads to mixed changes
- **Setup repetition**: Each new session requires re-running install scripts, setting up env files
- **No isolation**: A broken experiment can pollute the main working copy
- **Terminal juggling**: Multiple terminal windows/tabs without clear organization

## Solution Summary

**Workspaces** is a Mac-native app that creates isolated copies ("workspaces") of git repositories with embedded terminal support. Each workspace is a clean slate with automatic setup, making it trivial to spin up parallel AI coding sessions.

Think of it as **git worktrees with a terminal-first UI and lifecycle automation**.

## Core Capabilities

- **Repository Management**: Add git repos from your Mac, track them in sidebar
- **Workspace Creation**: Click `+` on any repo to create an isolated workspace copy
- **Lifecycle Hooks**: `setup.sh` runs after creation, `archive.sh` runs on close
- **Embedded Terminal**: Full SwiftTerm terminal as the primary interface
- **File/Changes Pane**: Collapsible right pane showing file tree and git status
- **Configurable Location**: Choose where workspaces are stored (default: `~/workspaces`)

## Sidebar Structure

The sidebar uses a **nested hierarchy** where workspaces belong to their parent repo:

```
┌──────────────────┐
│ M my-api      ⋯ +│  ← Repo with letter avatar, menu, + button
│   ↳ feature-auth │  ← Workspace nested underneath
│     main · 2m    │    Shows branch and time since activity
│   ↳ bugfix-nav   │
│     main · 39m   │
│                  │
│ F frontend    ⋯ +│  ← Another repo (no workspaces yet)
│                  │
│ S services    ⋯ +│
│   ↳ ios-oauth  ◀─│  ← Selected workspace (highlighted)
│     bozeman · PR │
├──────────────────┤
│ [+] Add repo     │  ← Add new repository
└──────────────────┘
```

**Key interactions:**
- Click `+` on repo row → opens "New Workspace" modal
- Click `⋯` on repo row → menu: Reveal in Finder, Remove
- Click workspace → switches terminal to that directory
- Click `⋯` on workspace row → menu: Delete, Reveal in Finder

## Target Users

### Primary: AI-Augmented Developer
Developers who regularly use Claude Code, Cursor, or similar AI coding tools. They:
- Work on multiple features/experiments concurrently
- Value clean separation between work streams
- Prefer terminal-based workflows over heavy IDEs
- Want quick setup without manual repetition

### Secondary: Solo Developer / Freelancer
Developers juggling multiple client projects who need:
- Quick context switching between codebases
- Isolated environments for each client
- Easy project cleanup when work completes

## Design Principles

1. **Terminal-First**: The embedded terminal IS the experience. This is not a code editor — use your preferred external editor alongside.

2. **Native Mac Feel**: SwiftUI + AppKit patterns. Three-column layout like Finder/Mail. Keyboard shortcuts that feel familiar.

3. **Non-Destructive**: Source repos are never modified. Workspaces are copies. Deleting a workspace doesn't touch the original.

4. **Offline-First**: Works without internet. Git remotes are optional. All operations are local.

5. **Minimal Chrome**: The terminal gets maximum screen real estate. Right pane collapses. Sidebar can hide.

## What This Is NOT

- **Not an IDE**: No syntax highlighting, code navigation, or LSP
- **Not a container manager**: Isolation is filesystem-level (copy), not Docker/VM
- **Not a git client**: Basic status display only; use terminal for git operations
- **Not multi-platform**: Mac-only, uses macOS-specific frameworks
