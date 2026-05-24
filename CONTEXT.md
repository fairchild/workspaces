# WorkSpaces Native App

WorkSpaces is the native macOS context for managing terminal-first AI coding work across a portfolio of local repositories. It exists to keep concurrent coding sessions organized, resumable, and isolated without turning the product into an IDE.

## Language

**WorkSpaces**:
The Mac-native app for terminal-first AI coding session management.
_Avoid_: Spaces, WorkspaceManager, IDE

**Repository**:
A tracked local codebase that anchors overviews, terminals, workspaces, and repo-owned web sources.
_Avoid_: Project, folder, account

**Workspace**:
An isolated working copy or provider-backed environment created from a repository for a single work stream.
_Avoid_: Session, tab, branch

**Terminal Session**:
A resumable terminal context attached to a repository or workspace.
_Avoid_: Shell, pane, console

**Surface**:
The currently selected main content target, such as a repo overview, repository terminal, workspace terminal, or web view.
_Avoid_: Page, screen, route

**Repo Overview**:
The repository-level surface for navigation and launch actions before entering a terminal or web view.
_Avoid_: Dashboard, home page

**Web Source**:
A saved web destination owned globally, by a repository, or by a workspace.
_Avoid_: Bookmark, browser tab, website

**Detail Pane**:
The collapsible right-side supporting pane for files, changes, and selected-context details.
_Avoid_: Inspector, sidebar, editor

**Agent**:
An AI coding assistant the developer drives from inside a **Terminal Session** — Claude Code, Codex, Aider, or similar. Agents have observable **Run State** (idle, thinking, running tool, awaiting input, errored, complete).
_Avoid_: Bot, assistant, copilot

**Workspace Event**:
A single observable change in an **Agent**'s **Run State** within a **Workspace** — started, transitioned, ran a tool, errored, completed. Persisted to local state so the Timeline narrates the past, not just the present.
_Avoid_: Log line, message, activity item

**Workspace Journal**:
The per-**Workspace** read API over **Workspace Events**, ordered newest first. The Timeline tab of the **Detail Pane** consumes it.
_Avoid_: Log, history, activity feed, audit trail

**Terminal Command Status**:
The last shell command observed in a **Terminal Session** — its exit code, duration, and whether it is still running. Sourced from OSC 133 prompt marks or an equivalent shell hook.
_Avoid_: Exit status, shell result, return code

**Diff**:
A unified `git diff` for a single file in a **Workspace**, structured as hunks of context / added / removed lines. The Changes tab of the **Detail Pane** renders it inline.
_Avoid_: Patch, changeset, edit

**Branch**:
A git branch in a **Repository** or **Workspace**. The **Workspace** creation flow can target an existing branch; the Detail Pane surfaces the current one.
_Avoid_: Ref, head, version

**Attention**:
The project-wide rollup of **Workspaces** or **Repositories** that currently demand the user — agents that are awaiting input or have errored. Drives the "N need you" toolbar indicator.
_Avoid_: Notifications, alerts, warnings, tasks

## Relationships

- A **Repository** owns zero or more **Workspaces**.
- A **Repository** owns zero or more repo-scoped **Web Sources**.
- A **Workspace** belongs to exactly one **Repository**.
- A **Workspace** owns zero or more workspace-scoped **Web Sources**.
- A **Terminal Session** attaches to either a **Repository** or a **Workspace**.
- A **Surface** is one selected **Repo Overview**, repository **Terminal Session**, workspace **Terminal Session**, or **Web Source**.
- The **Detail Pane** follows the selected **Surface** when that surface has repository or workspace context.
- An **Agent** runs inside a **Terminal Session** and emits **Workspace Events** that the **Workspace Journal** persists.
- A **Terminal Session** observes its own **Terminal Command Status** independently of any **Agent** running inside it.
- **Attention** rolls up across all **Workspaces** and **Repositories**; the rollup at any moment determines the toolbar indicator.

## Example Dialogue

> **Dev:** "When I click a **Repository**, do I immediately enter its **Terminal Session**?"
> **Domain expert:** "No. A repository click opens the **Repo Overview**. You enter a **Terminal Session** only when you choose the repository terminal or a **Workspace**."

## Flagged Ambiguities

- "Spaces" was used for the web chat/dashboard docs, while "WorkSpaces" names the native macOS app. Resolved: this context uses **WorkSpaces** for the native app; **Spaces** belongs to a separate web/chat context.
- "Session" can mean a terminal process, an agent conversation, or a work stream. Resolved: use **Terminal Session** for the native terminal context and **Workspace** for the isolated work stream. Never use bare "Session" in domain types or API surfaces.
- "Event" without a scope was ambiguous between **Workspace Events** (agent state changes inside a workspace) and webhook events from external systems. Resolved: use **Workspace Event** for the in-app domain type; reserve "webhook event" (lowercased, qualified) for the external GitHub stream.
- "Journal" vs "log" vs "history" — domain reads use **Workspace Journal**; "log" stays a runtime/diagnostic term; "history" is informal narration and shouldn't appear in types.
- "Status" is overloaded — there is workspace **Agent** status, **Terminal Command Status**, and git status (file changes). Resolved: qualify every use; never ship a public `status:` property without a scope-revealing prefix.
