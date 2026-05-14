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

## Relationships

- A **Repository** owns zero or more **Workspaces**.
- A **Repository** owns zero or more repo-scoped **Web Sources**.
- A **Workspace** belongs to exactly one **Repository**.
- A **Workspace** owns zero or more workspace-scoped **Web Sources**.
- A **Terminal Session** attaches to either a **Repository** or a **Workspace**.
- A **Surface** is one selected **Repo Overview**, repository **Terminal Session**, workspace **Terminal Session**, or **Web Source**.
- The **Detail Pane** follows the selected **Surface** when that surface has repository or workspace context.

## Example Dialogue

> **Dev:** "When I click a **Repository**, do I immediately enter its **Terminal Session**?"
> **Domain expert:** "No. A repository click opens the **Repo Overview**. You enter a **Terminal Session** only when you choose the repository terminal or a **Workspace**."

## Flagged Ambiguities

- "Spaces" was used for the web chat/dashboard docs, while "WorkSpaces" names the native macOS app. Resolved: this context uses **WorkSpaces** for the native app; **Spaces** belongs to a separate web/chat context.
- "Session" can mean a terminal process, an agent conversation, or a work stream. Resolved: use **Terminal Session** for the native terminal context and **Workspace** for the isolated work stream.
