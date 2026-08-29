import Testing

@testable import WorkspaceManager

@Suite("Sidebar header inline actions")
struct SidebarHeaderActionsTests {
    @Test("The topmost header with repos carries sort; add stays with the toolbar")
    func topmostWithReposDefaultToolbar() {
        let actions = SidebarHeaderActions.forHeader(
            isTopmost: true, hasRepos: true, isToolbarMinimal: false)
        #expect(actions == SidebarHeaderActions(showsSort: true, showsAdd: false))
    }

    /// The duplicate-control regression this suite exists to catch: with the default toolbar
    /// showing its own add menu, the header must not stack a second one beside it.
    @Test("A default toolbar never gets a header add menu")
    func defaultToolbarNeverDuplicatesAdd() {
        for hasRepos in [true, false] {
            let actions = SidebarHeaderActions.forHeader(
                isTopmost: true, hasRepos: hasRepos, isToolbarMinimal: false)
            #expect(actions.showsAdd == false)
        }
    }

    @Test("A minimal toolbar moves add into the topmost header")
    func minimalToolbarCarriesAdd() {
        let actions = SidebarHeaderActions.forHeader(
            isTopmost: true, hasRepos: true, isToolbarMinimal: true)
        #expect(actions == SidebarHeaderActions(showsSort: true, showsAdd: true))
    }

    /// The empty-sidebar regression from the first review round: under a minimal toolbar the
    /// header add menu is the app's only route to Add Repository (#1425), so unlike sort it
    /// must survive an empty sidebar.
    @Test("An empty sidebar under a minimal toolbar keeps add and stands sort down")
    func minimalToolbarEmptySidebarKeepsAdd() {
        let actions = SidebarHeaderActions.forHeader(
            isTopmost: true, hasRepos: false, isToolbarMinimal: true)
        #expect(actions == SidebarHeaderActions(showsSort: false, showsAdd: true))
    }

    @Test("Only the topmost header carries actions")
    func notTopmost() {
        for hasRepos in [true, false] {
            for isToolbarMinimal in [true, false] {
                let actions = SidebarHeaderActions.forHeader(
                    isTopmost: false, hasRepos: hasRepos, isToolbarMinimal: isToolbarMinimal)
                #expect(actions == SidebarHeaderActions(showsSort: false, showsAdd: false))
            }
        }
    }
}
