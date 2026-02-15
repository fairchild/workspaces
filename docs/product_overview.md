# Workspaces — Product Overview

## Problem Statement

Developers using AI coding assistants (Claude Code, Cursor, Copilot) face friction when managing concurrent work:

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
- **Lifecycle Hooks**: `setup.sh` runs after creation, `archive.sh` runs on close
- **Embedded Terminal**: GhosttyKit (`libghostty`) terminal as the primary interface
- **File/Changes Pane**: Collapsible right pane showing file tree and git status
- **Configurable Location**: Choose where workspaces are stored (default: `~/workspaces`)

## Sidebar Structure

The sidebar is split into **Repositories** and **Workspaces** sections with explicit host/session controls:

```
┌──────────────────┐
│ Host Portfolio [LIVE] │  ← One-click return to default host terminal
│                  │
│ [repo] my-api LIVE │  ← Repo rows can show live terminal badge
│ [repo] frontend    │
│ [repo] services    │
│                  │
│ Workspaces       │
│ ◀ feature-auth   │  ← Selected workspace (drives right pane context)
│   bugfix-nav     │
├──────────────────┤
│ [+] Add repo     │  ← Add new repository
└──────────────────┘
```

**Key interactions:**
- Click `Host Portfolio` row → switch back to the default `~/code` host session
- Click repo row → open/resume persistent host terminal session for that repo path
- Click workspace row → open/resume persistent host terminal session for that workspace path and update right pane context
- Click `+`/`New Workspace` action on a repo → opens "New Workspace" modal
- Click `⋯` on repo row → menu: Reveal in Finder, Remove
- Click `⋯` on workspace row → menu: Delete, Reveal in Finder

## Target Users

### Primary: AI-Augmented Developer
Developers who regularly use Claude Code, Cursor, or similar AI coding tools. They:
- Work on multiple features/experiments concurrently
- Value clean separation between work streams
- Prefer terminal-based workflows over heavy IDEs
- Want quick setup without manual repetition

## Design Principles

1. **Terminal-First**: The embedded terminal IS the experience. This is not a code editor — use your preferred external editor alongside.

2. **Native Mac Feel**: SwiftUI + AppKit patterns. Three-column layout like Finder/Mail. Keyboard shortcuts that feel familiar.

3. **Non-Destructive**: Source repos are never modified. Workspaces are copies. Deleting a workspace doesn't touch the original.

4. **Offline-First**: Works without internet. Git remotes are optional. All operations are local.

5. **Minimal Chrome**: The terminal gets maximum screen real estate. Right pane collapses. Sidebar can hide.

## What This Is NOT

- **Not an IDE**: No syntax highlighting, code navigation, or LSP
- **Not VM-based yet**: Host-local isolation (filesystem copy) is the default. VM-backed workspaces via macOS 26 Virtualization.framework are the next planned phase
- **Not a git client**: Basic status display only; use terminal for git operations
- **Not multi-platform**: Mac-only, uses macOS-specific frameworks
