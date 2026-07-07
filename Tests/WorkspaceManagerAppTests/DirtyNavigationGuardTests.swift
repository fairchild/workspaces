import Testing

@testable import WorkspaceManager

@Suite("DirtyNavigationGuard")
struct DirtyNavigationGuardTests {
    @Test("a clean editor never prompts")
    func cleanEditorNeverPrompts() {
        #expect(!DirtyNavigationGuard.requiresPrompt(isDirty: false))
    }

    @Test("a dirty editor prompts before navigating")
    func dirtyEditorPrompts() {
        #expect(DirtyNavigationGuard.requiresPrompt(isDirty: true))
    }

    @Test("Save saves before proceeding, Discard proceeds, Cancel vetoes")
    func choiceMapsToOutcome() {
        #expect(DirtyNavigationGuard.outcome(for: .save) == .saveThenProceed)
        #expect(DirtyNavigationGuard.outcome(for: .discard) == .proceed)
        #expect(DirtyNavigationGuard.outcome(for: .cancel) == .veto)
    }
}
