//
//  SidebarHeaderActions.swift
//  WorkspaceManager
//
//  Decides which inline menus a sidebar section header shows. Pure, so the placement
//  rule — one action-bearing header, add always reachable — is testable without
//  constructing SidebarView and its app graph.
//

/// Visibility of the inline menus in a sidebar section header.
///
/// The topmost header carries the sidebar's inline actions — sort and add — for whichever
/// section heads the list: Pinned when it exists, otherwise the arrangement's own first
/// header. The two part company on an empty sidebar: sort stands down with nothing to
/// sort, while add is precisely what that state is waiting for — and is the app's only
/// route to Add Repository once `minimalToolbar` hides the toolbar copy (#1425).
struct SidebarHeaderActions: Equatable {
    let showsSort: Bool
    let showsAdd: Bool

    static func forHeader(isTopmost: Bool, hasRepos: Bool) -> SidebarHeaderActions {
        SidebarHeaderActions(showsSort: isTopmost && hasRepos, showsAdd: isTopmost)
    }
}
