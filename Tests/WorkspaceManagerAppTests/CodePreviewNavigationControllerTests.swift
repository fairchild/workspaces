//
//  CodePreviewNavigationControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the editor's dirty-navigation flow: when opening or closing pauses for the
//  unsaved-changes prompt, what each answer does, and the generation-token rule that decides
//  whether a Save which awaited across a newer navigation may still commit its captured target.
//

import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("CodePreviewNavigation")
struct CodePreviewNavigationControllerTests {
    private let controller = CodePreviewNavigationController()

    private func selection(_ path: String) -> CodePreviewSelection {
        CodePreviewSelection(rootURL: URL(fileURLWithPath: "/tmp/repo"), relativePath: path)
    }

    // MARK: - Opening a file

    @Test("With a clean editor, opening a file navigates immediately")
    func openWithCleanEditorCommits() {
        let target = selection("b.swift")

        let action = controller.openAction(
            for: target,
            current: selection("a.swift"),
            hasUnsavedEdits: false
        )

        #expect(action == .commit(.open(target)))
    }

    @Test("Opening a different file over unsaved edits pauses for the prompt")
    func openDifferentFileOverDirtyEditorPrompts() {
        let target = selection("b.swift")

        let action = controller.openAction(
            for: target,
            current: selection("a.swift"),
            hasUnsavedEdits: true
        )

        #expect(action == .prompt(.open(target)))
    }

    @Test("Re-selecting the file already open never prompts, dirty or not")
    func reopeningTheCurrentFileCommits() {
        let target = selection("a.swift")

        let action = controller.openAction(for: target, current: target, hasUnsavedEdits: true)

        #expect(action == .commit(.open(target)))
    }

    @Test("With no file open there is nothing to lose, so opening commits")
    func openWithNothingOpenCommits() {
        let target = selection("a.swift")

        let action = controller.openAction(for: target, current: nil, hasUnsavedEdits: true)

        #expect(action == .commit(.open(target)))
    }

    // MARK: - Closing the preview

    @Test("Closing a dirty editor pauses for the prompt")
    func closeWithDirtyEditorPrompts() {
        let action = controller.closeAction(current: selection("a.swift"), hasUnsavedEdits: true)

        #expect(action == .prompt(.close))
    }

    @Test("Closing a clean editor closes immediately")
    func closeWithCleanEditorCommits() {
        let action = controller.closeAction(current: selection("a.swift"), hasUnsavedEdits: false)

        #expect(action == .commit(.close))
    }

    @Test("Closing with nothing open commits even while another document is dirty")
    func closeWithNothingOpenCommits() {
        let action = controller.closeAction(current: nil, hasUnsavedEdits: true)

        #expect(action == .commit(.close))
    }

    // MARK: - Answering the prompt

    @Test("Cancel drops the intent, Discard navigates, Save writes first")
    func promptAnswersMapToResolutions() {
        let pending = PendingCodePreviewNavigation.open(selection("b.swift"))

        #expect(controller.resolution(for: .cancel, pending: pending) == .dismiss)
        #expect(controller.resolution(for: .discard, pending: pending) == .commit(pending))
        #expect(controller.resolution(for: .save, pending: pending) == .saveThenCommit(pending))
    }

    @Test("A close intent survives the prompt as a close, not as an open")
    func closeIntentRoundTripsThroughThePrompt() {
        #expect(
            controller.resolution(for: .discard, pending: .close) == .commit(.close)
        )
    }

    // MARK: - Deferred-navigation state

    @Test("Raising a navigation records it and bumps the generation")
    func raiseRecordsPendingAndBumpsGeneration() {
        var state = CodePreviewNavigationState()
        let target = selection("b.swift")

        #expect(state.pending == nil)
        let before = state.generation

        state.raise(.open(target))

        #expect(state.pending == .open(target))
        #expect(state.generation == before &+ 1)
    }

    @Test("Dismissing the prompt clears the intent without bumping the generation")
    func clearPendingLeavesGenerationAlone() {
        var state = CodePreviewNavigationState()
        state.raise(.close)
        let generation = state.generation

        state.clearPending()

        #expect(state.pending == nil)
        #expect(state.generation == generation)
    }

    /// The happy path: Save completes, nothing else happened, the document is clean.
    @Test("An uncontested save commits the target it captured")
    func deferredCommitProceedsWhenNothingSuperseded() {
        var state = CodePreviewNavigationState()
        state.raise(.open(selection("b.swift")))
        let captured = state.generation

        #expect(state.canCommitDeferred(capturedGeneration: captured, hasUnsavedEdits: false))
    }

    /// The rule this slice exists to pin: a navigation raised while the save was in flight
    /// bumps the generation, so the older intent must not land the user on a stale file.
    @Test("A navigation raised during the save supersedes the captured target")
    func deferredCommitIsVetoedBySupersedingNavigation() {
        var state = CodePreviewNavigationState()
        state.raise(.open(selection("b.swift")))
        let captured = state.generation

        // User picks a third file while the write is still in flight.
        state.raise(.open(selection("c.swift")))

        #expect(
            state.canCommitDeferred(capturedGeneration: captured, hasUnsavedEdits: false) == false
        )
    }

    /// Typing during the save leaves the document dirty again; committing would drop those edits.
    @Test("Edits typed during the save veto the deferred commit")
    func deferredCommitIsVetoedByFreshEdits() {
        var state = CodePreviewNavigationState()
        state.raise(.open(selection("b.swift")))
        let captured = state.generation

        #expect(
            state.canCommitDeferred(capturedGeneration: captured, hasUnsavedEdits: true) == false
        )
    }

    /// Dismissing the dialog must not silently re-enable a superseded save: clearing the intent
    /// leaves the generation alone, so an in-flight capture stays valid on its own terms.
    @Test("Clearing the pending intent does not by itself veto an in-flight save")
    func clearPendingDoesNotVetoDeferredCommit() {
        var state = CodePreviewNavigationState()
        state.raise(.open(selection("b.swift")))
        let captured = state.generation

        state.clearPending()

        #expect(state.canCommitDeferred(capturedGeneration: captured, hasUnsavedEdits: false))
    }

    /// The same rule with a real suspension between capture and check, mirroring the production
    /// shape: capture the generation, await, then read. This pins the ordering; it does not reach
    /// the `@State` wrapper itself, so it would not catch production snapshotting the struct into
    /// a local before the Task instead of reading through the wrapper after it. That property was
    /// verified out-of-band by a hosted-SwiftUI probe during review — see the PR's Review loop.
    @Test("A navigation raised across a suspension still supersedes the captured target")
    func deferredCommitIsVetoedAcrossASuspension() async {
        var state = CodePreviewNavigationState()
        state.raise(.open(selection("b.swift")))
        let captured = state.generation

        await Task.yield()
        state.raise(.open(selection("c.swift")))
        await Task.yield()

        #expect(
            state.canCommitDeferred(capturedGeneration: captured, hasUnsavedEdits: false) == false
        )
    }

    /// End-to-end ordering over the real sequence: open A dirty → prompt → Save → user opens C
    /// mid-save → the save resolves. C must win.
    @Test("Across a full save-then-supersede sequence the newer navigation wins")
    func fullSupersessionSequence() {
        var state = CodePreviewNavigationState()

        let first = controller.openAction(
            for: selection("b.swift"),
            current: selection("a.swift"),
            hasUnsavedEdits: true
        )
        guard case .prompt(let firstIntent) = first else {
            Issue.record("Expected the first open to prompt")
            return
        }
        state.raise(firstIntent)

        #expect(controller.resolution(for: .save, pending: firstIntent) == .saveThenCommit(firstIntent))
        let captured = state.generation

        let second = controller.openAction(
            for: selection("c.swift"),
            current: selection("a.swift"),
            hasUnsavedEdits: true
        )
        guard case .prompt(let secondIntent) = second else {
            Issue.record("Expected the second open to prompt")
            return
        }
        state.raise(secondIntent)

        #expect(
            state.canCommitDeferred(capturedGeneration: captured, hasUnsavedEdits: false) == false
        )
        #expect(state.pending == secondIntent)
    }
}
