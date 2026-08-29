//
//  SidebarHeaderActions.swift
//  WorkspaceManager
//
//  Decides which inline menus a sidebar section header shows. Pure, so the placement
//  rule — one action-bearing header, one add surface at a time — is testable without
//  constructing SidebarView and its app graph.
//

/// Visibility of the inline menus in a sidebar section header.
///
/// The topmost header carries the sidebar's inline actions for whichever section heads the
/// list: Pinned when it exists, otherwise the arrangement's own first header. Sort stands
/// down with nothing to sort. Add appears only while `minimalToolbar` hides the toolbar's
/// copy — the header is the fallback route, never a duplicate — and unlike sort it ignores
/// the empty-sidebar guard, because with the toolbar minimal it is the app's only route to
/// Add Repository and an empty sidebar is precisely what that route is for (#1425).
struct SidebarHeaderActions: Equatable {
    let showsSort: Bool
    let showsAdd: Bool

    static func forHeader(
        isTopmost: Bool,
        hasRepos: Bool,
        isToolbarMinimal: Bool
    ) -> SidebarHeaderActions {
        SidebarHeaderActions(
            showsSort: isTopmost && hasRepos,
            showsAdd: isTopmost && isToolbarMinimal
        )
    }
}
