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

    @Test("a deferred save-then-navigate commits only when nothing superseded it and the doc is clean")
    func deferredNavigationCommitRules() {
        // Nothing changed during the save and the document saved clean: commit.
        #expect(
            DirtyNavigationGuard.shouldCommitDeferredNavigation(
                capturedGeneration: 3, currentGeneration: 3, hasUnsavedEdits: false))

        // A newer navigation arrived during the await (generation bumped): do not commit the stale
        // target — the newer navigation owns the outcome now.
        #expect(
            !DirtyNavigationGuard.shouldCommitDeferredNavigation(
                capturedGeneration: 3, currentGeneration: 4, hasUnsavedEdits: false))

        // The user typed more while the write was in flight, so the document is dirty again: do not
        // navigate away and drop those edits.
        #expect(
            !DirtyNavigationGuard.shouldCommitDeferredNavigation(
                capturedGeneration: 3, currentGeneration: 3, hasUnsavedEdits: true))

        // Both conditions bad: still no commit.
        #expect(
            !DirtyNavigationGuard.shouldCommitDeferredNavigation(
                capturedGeneration: 3, currentGeneration: 5, hasUnsavedEdits: true))
    }
}
