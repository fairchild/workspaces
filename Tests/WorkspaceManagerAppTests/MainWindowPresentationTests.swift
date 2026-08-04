//
//  MainWindowPresentationTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the two rules every main-window confirmation depends on: an optional decides
//  presentation and only a dismissal clears it, and a confirming button takes the pending value
//  before it acts so the alert it just answered cannot re-present.
//

import SwiftUI
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowPresentation")
struct MainWindowPresentationTests {
    /// Stands in for the view state an alert reads, so the `@autoclosure` overloads re-evaluate
    /// their source the way they do against a live `@State`.
    private final class Box<Item> {
        var value: Item?
        init(_ value: Item? = nil) { self.value = value }

        var binding: Binding<Item?> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    // MARK: - Presentation from an optional

    @Test("An alert presents exactly while its item is set")
    func presentationFollowsTheItem() {
        let box = Box<String>()
        let isPresented = MainWindowPresentation.isPresented(box.binding)

        #expect(isPresented.wrappedValue == false)

        box.value = "pending"

        #expect(isPresented.wrappedValue)
    }

    @Test("Dismissing clears the item")
    func dismissingClearsTheItem() {
        let box = Box("pending")
        let isPresented = MainWindowPresentation.isPresented(box.binding)

        isPresented.wrappedValue = false

        #expect(box.value == nil)
    }

    /// The item is what decides presentation, so a `true` write has nothing to act on. Inventing
    /// a value to satisfy it would present an alert about nothing.
    @Test("Setting presented true does not invent an item")
    func settingPresentedTrueDoesNothing() {
        let box = Box<String>()
        let isPresented = MainWindowPresentation.isPresented(box.binding)

        isPresented.wrappedValue = true

        #expect(box.value == nil)
        #expect(isPresented.wrappedValue == false)
    }

    /// The case that actually binds the "only a dismissal clears" rule: SwiftUI re-asserting
    /// presentation on a live alert must not destroy the item the alert is about. Asserting this
    /// against an already-empty source proves nothing, because clearing nothing looks identical.
    @Test("Re-asserting presentation leaves a live item intact")
    func reassertingPresentationKeepsTheItem() {
        let box = Box("pending")
        let isPresented = MainWindowPresentation.isPresented(box.binding)

        isPresented.wrappedValue = true

        #expect(box.value == "pending")
        #expect(isPresented.wrappedValue)
    }

    // MARK: - Sources that own their teardown

    @Test("A coordinator-backed alert runs its own teardown on dismissal")
    func coordinatorTeardownRunsOnDismissal() {
        let box = Box("failed")
        var teardownCount = 0
        let isPresented = MainWindowPresentation.isPresented(
            box.value,
            onDismiss: { teardownCount += 1 }
        )

        #expect(isPresented.wrappedValue)

        isPresented.wrappedValue = false

        #expect(teardownCount == 1)
        // The teardown owns the clearing; the binding must not also assign.
        #expect(box.value == "failed")
    }

    @Test("Re-asserting presentation does not run the teardown")
    func coordinatorTeardownIgnoresTrue() {
        let box = Box("failed")
        var teardownCount = 0
        let isPresented = MainWindowPresentation.isPresented(
            box.value,
            onDismiss: { teardownCount += 1 }
        )

        isPresented.wrappedValue = true

        #expect(teardownCount == 0)
    }

    @Test("An item sheet cancels its pending work when dismissed")
    func itemSheetCancelsOnDismissal() {
        let box = Box("request")
        var cancelCount = 0
        let binding = MainWindowPresentation.item(box.value, onDismiss: { cancelCount += 1 })

        #expect(binding.wrappedValue == "request")

        binding.wrappedValue = nil

        #expect(cancelCount == 1)
    }

    @Test("Assigning a new item does not cancel pending work")
    func itemSheetIgnoresNonNilWrites() {
        let box = Box("request")
        var cancelCount = 0
        let binding = MainWindowPresentation.item(box.value, onDismiss: { cancelCount += 1 })

        binding.wrappedValue = "another"

        #expect(cancelCount == 0)
    }

    /// The progress sheet closes when its owner finishes, never because the user waved it away.
    @Test("An undismissable sheet ignores dismissal entirely")
    func undismissableSheetIgnoresDismissal() {
        let box = Box("in progress")
        let binding = MainWindowPresentation.undismissableItem(box.value)

        #expect(binding.wrappedValue == "in progress")

        binding.wrappedValue = nil

        #expect(box.value == "in progress")
        #expect(binding.wrappedValue == "in progress")
    }

    // MARK: - Consume before acting

    @Test("Consuming returns the pending value and clears it")
    func consumeReturnsAndClears() {
        let box = Box("item")

        #expect(MainWindowPresentation.consume(box.binding) == "item")
        #expect(box.value == nil)
    }

    /// The rule this extraction locks in. A confirming action can present again — a cleanup that
    /// rescans, a close that raises the next confirmation — so the value has to be gone before
    /// the action runs, or the answered alert comes straight back.
    @Test("A second consume finds nothing, so the answered alert cannot re-present")
    func consumeIsSingleShot() {
        let box = Box("item")

        let first = MainWindowPresentation.consume(box.binding)
        let second = MainWindowPresentation.consume(box.binding)

        #expect(first == "item")
        #expect(second == nil)

        let isPresented = MainWindowPresentation.isPresented(box.binding)
        #expect(isPresented.wrappedValue == false)
    }

    /// A button action can still arrive after the state cleared, so consuming an empty source has
    /// to be a no-op rather than a crash or a spurious action.
    @Test("Consuming nothing returns nil and leaves the source alone")
    func consumeEmptyIsANoOp() {
        let box = Box<String>()

        #expect(MainWindowPresentation.consume(box.binding) == nil)
        #expect(box.value == nil)
    }
}
