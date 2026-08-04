//
//  CodePreviewNavigationController.swift
//  WorkspaceManager
//
//  The editor's dirty-navigation flow (#704 Phase 4): whether opening another file or closing
//  the preview proceeds now or pauses for Save / Discard / Cancel, and whether a Save that
//  awaited across a newer navigation may still commit the target it captured.
//  `DirtyNavigationGuard` owns the rules; this owns the state they read and the intents they
//  produce, so the main window's use of the guard is testable without a window.
//

import Foundation

/// A code-preview navigation intent deferred behind the dirty-editor prompt.
enum PendingCodePreviewNavigation: Equatable {
    case open(CodePreviewSelection)
    case close
}

/// Deferred-navigation state for the code preview, held in one `@State`.
struct CodePreviewNavigationState: Equatable {
    /// The navigation held back by the unsaved-changes prompt. Non-nil presents the dialog.
    private(set) var pending: PendingCodePreviewNavigation?

    /// Monotonic token bumped each time a new pending navigation is raised, so a Save that
    /// awaits across a newer navigation can detect it was superseded and decline to commit
    /// its stale target.
    private(set) var generation = 0

    mutating func raise(_ navigation: PendingCodePreviewNavigation) {
        generation &+= 1
        pending = navigation
    }

    mutating func clearPending() {
        pending = nil
    }

    /// Whether a Save-then-navigate that awaited an async save may still commit the target it
    /// captured. Taking `currentGeneration` from `self` rather than an argument is the point:
    /// the captured token comes from before the await, the current one from live state after
    /// it, so a navigation raised in between wins by construction.
    func canCommitDeferred(capturedGeneration: Int, hasUnsavedEdits: Bool) -> Bool {
        DirtyNavigationGuard.shouldCommitDeferredNavigation(
            capturedGeneration: capturedGeneration,
            currentGeneration: generation,
            hasUnsavedEdits: hasUnsavedEdits
        )
    }
}

@MainActor
struct CodePreviewNavigationController {
    /// What a navigation intent does right now.
    enum NavigationAction: Equatable {
        /// Nothing needed saving — navigate immediately.
        case commit(PendingCodePreviewNavigation)
        /// Hold the intent behind the unsaved-changes prompt.
        case prompt(PendingCodePreviewNavigation)
    }

    /// What the user's answer to the prompt does.
    enum PromptResolution: Equatable {
        /// Cancel: drop the intent, leaving file and selection untouched.
        case dismiss
        /// Discard: navigate now.
        case commit(PendingCodePreviewNavigation)
        /// Save: write first, then navigate only if nothing superseded the intent.
        case saveThenCommit(PendingCodePreviewNavigation)
    }

    /// Opening a file. Only a *different* file over a dirty editor prompts — re-selecting the
    /// file already open is not navigation, so it never pauses.
    func openAction(
        for selection: CodePreviewSelection,
        current: CodePreviewSelection?,
        hasUnsavedEdits: Bool
    ) -> NavigationAction {
        if DirtyNavigationGuard.requiresPrompt(isDirty: hasUnsavedEdits),
            let current,
            current.id != selection.id
        {
            return .prompt(.open(selection))
        }
        return .commit(.open(selection))
    }

    /// Closing the preview from the editor's own Close button or the terminal toggle. Prompts
    /// whenever a dirty file is open; with nothing open there is nothing to lose.
    func closeAction(
        current: CodePreviewSelection?,
        hasUnsavedEdits: Bool
    ) -> NavigationAction {
        if DirtyNavigationGuard.requiresPrompt(isDirty: hasUnsavedEdits), current != nil {
            return .prompt(.close)
        }
        return .commit(.close)
    }

    func resolution(
        for choice: DirtyNavigationChoice,
        pending: PendingCodePreviewNavigation
    ) -> PromptResolution {
        switch DirtyNavigationGuard.outcome(for: choice) {
        case .veto:
            return .dismiss
        case .proceed:
            return .commit(pending)
        case .saveThenProceed:
            return .saveThenCommit(pending)
        }
    }
}
