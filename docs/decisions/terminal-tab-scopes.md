# Terminal Tab Scopes

## Status

Accepted

## Context

Host terminal tabs were stored in one flat list and rendered globally. That kept
terminals alive across navigation, but it meant a workspace surface could show tabs
from Home, another workspace, and the repository root at the same time.

The repo-root terminal is easy to mistake for a workspace because it has terminal
tabs and can run agents. It is not a workspace: a workspace is an isolated copy or
provider-backed environment created from a repository for a single work stream.

## Decision

Treat terminal tabs as collections owned by a **Terminal Scope**. A scope is exactly
one of:

- Home (`~/code`)
- a Repository
- a Workspace

`HostTerminalSessionKey` is the scope identity. Tabs remain in the coordinator's flat
session list, but tab rendering, tab navigation, tab reordering, and close-other /
close-right operations filter by the active scope key.

The repo-root terminal remains a Repository-scoped Terminal Session. It is reached
from the Repo Overview, and when repository tabs already exist the sidebar repository
row resumes that terminal collection directly. The repo-terminal header provides the
breadcrumb back to the Repo Overview.

## Consequences

- We preserve the invariant that workspaces are isolated copies or remote
  environments, not the repository root.
- Terminal processes can stay alive globally while the visible tab strip remains
  local to the current Home, Repository, or Workspace scope.
- There is no new tab-group data model. The ordered flat list remains the source of
  truth, with `HostTerminalSessionKey` providing the grouping boundary.
- Launch continuity must persist both the flat tab list and the active tab for each
  scope, otherwise a restored repository row could not resume the same tab collection.
