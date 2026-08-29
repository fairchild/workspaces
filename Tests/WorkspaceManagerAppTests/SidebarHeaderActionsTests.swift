import Testing

@testable import WorkspaceManager

@Suite("Sidebar header inline actions")
struct SidebarHeaderActionsTests {
    @Test("The topmost header with repos carries both menus")
    func topmostWithRepos() {
        let actions = SidebarHeaderActions.forHeader(isTopmost: true, hasRepos: true)
        #expect(actions == SidebarHeaderActions(showsSort: true, showsAdd: true))
    }

    /// The regression this suite exists to catch: pairing add under sort's empty gate would
    /// leave an empty sidebar with no route to Add Repository once `minimalToolbar` hides
    /// the toolbar copy (#1425).
    @Test("An empty sidebar keeps add and stands sort down")
    func topmostWithoutRepos() {
        let actions = SidebarHeaderActions.forHeader(isTopmost: true, hasRepos: false)
        #expect(actions == SidebarHeaderActions(showsSort: false, showsAdd: true))
    }

    @Test("Only the topmost header carries actions")
    func notTopmost() {
        for hasRepos in [true, false] {
            let actions = SidebarHeaderActions.forHeader(isTopmost: false, hasRepos: hasRepos)
            #expect(actions == SidebarHeaderActions(showsSort: false, showsAdd: false))
        }
    }
}
