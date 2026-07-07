//
//  DirtyNavigationGuard.swift
//  WorkspaceManager
//
//  Pure decision for the editor's dirty-navigation veto (#704 Phase 4): given whether the open
//  document has unsaved edits and, when it does, the user's Save / Discard / Cancel choice, it
//  says whether a navigation intent (opening another file, closing the preview) proceeds, saves
//  first, or is vetoed. Keeping the decision here — separate from the SwiftUI wiring — makes the
//  contract testable without a running window.
//

enum DirtyNavigationChoice: Equatable {
    case save
    case discard
    case cancel
}

enum DirtyNavigationOutcome: Equatable {
    /// Perform the navigation now (nothing needed saving, or the user chose Discard).
    case proceed
    /// Save the document first; only navigate if the save succeeds.
    case saveThenProceed
    /// Veto: leave the current file and selection untouched.
    case veto
}

enum DirtyNavigationGuard {
    /// Whether a navigation intent must pause for a Save / Discard / Cancel prompt.
    static func requiresPrompt(isDirty: Bool) -> Bool {
        isDirty
    }

    /// Outcome once the user has answered the prompt (only meaningful when `requiresPrompt`).
    static func outcome(for choice: DirtyNavigationChoice) -> DirtyNavigationOutcome {
        switch choice {
        case .save:
            return .saveThenProceed
        case .discard:
            return .proceed
        case .cancel:
            return .veto
        }
    }
}
