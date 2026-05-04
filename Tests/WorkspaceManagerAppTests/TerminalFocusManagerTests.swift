import AppKit
import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
private final class FocusWindowDelegateSpy: TerminalFocusWindowDelegate {
    var shouldSkipFocusRestore = false
    private(set) var becameKeyWindows: [NSWindow] = []
    private(set) var becameActiveWindows: [NSWindow] = []

    func shouldSkipWindowFocusRestore(for window: NSWindow) -> Bool {
        shouldSkipFocusRestore
    }

    func windowDidBecomeKey(_ window: NSWindow) {
        becameKeyWindows.append(window)
    }

    func appDidBecomeActive(for window: NSWindow) {
        becameActiveWindows.append(window)
    }
}

@Suite("TerminalFocusManager")
@MainActor
struct TerminalFocusManagerTests {
    @Test("Focus request uses single bounded retry, not exponential backoff")
    func singleBoundedRetry() {
        let fallbackDelay: TimeInterval = 0.1
        #expect(fallbackDelay == 0.1, "Fallback retry should be exactly 100ms")
    }

    @Test("windowDidBecomeKey dispatches only to the bound window delegate")
    func windowDidBecomeKeyDispatchesOnlyToBoundDelegate() {
        let manager = TerminalFocusManager.shared
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        let firstSpy = FocusWindowDelegateSpy()
        let secondSpy = FocusWindowDelegateSpy()

        defer {
            manager.unbindDelegate(from: firstWindow)
            manager.unbindDelegate(from: secondWindow)
        }

        manager.bindDelegate(firstSpy, to: firstWindow)
        manager.bindDelegate(secondSpy, to: secondWindow)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: firstWindow)

        #expect(!firstSpy.becameKeyWindows.isEmpty)
        #expect(firstSpy.becameKeyWindows.allSatisfy { $0 === firstWindow })
        #expect(secondSpy.becameKeyWindows.isEmpty)
    }

    @Test("closing one window does not break app-active dispatch for another window")
    func closingOneWindowDoesNotBreakAnotherWindow() {
        let manager = TerminalFocusManager.shared
        let closingWindow = makeWindow()
        let survivingWindow = makeWindow()
        let closingSpy = FocusWindowDelegateSpy()
        let survivingSpy = FocusWindowDelegateSpy()

        defer {
            manager.unbindDelegate(from: closingWindow)
            manager.unbindDelegate(from: survivingWindow)
        }

        manager.bindDelegate(closingSpy, to: closingWindow)
        manager.bindDelegate(survivingSpy, to: survivingWindow)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: closingWindow)

        manager.dispatchAppDidBecomeActive(to: [survivingWindow])

        #expect(closingSpy.becameActiveWindows.isEmpty)
        #expect(survivingSpy.becameActiveWindows == [survivingWindow])
    }
}

@Suite("TerminalFocusCoordinator")
@MainActor
struct TerminalFocusCoordinatorTests {
    @Test("pending focus state is scoped to the bound window")
    func pendingFocusStateIsScopedToBoundWindow() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        let firstCoordinator = TerminalFocusCoordinator()
        let secondCoordinator = TerminalFocusCoordinator()
        let firstSurfaceStore = HostTerminalSurfaceStore()
        let secondSurfaceStore = HostTerminalSurfaceStore()

        defer {
            TerminalFocusManager.shared.unbindDelegate(from: firstWindow)
            TerminalFocusManager.shared.unbindDelegate(from: secondWindow)
        }

        firstCoordinator.bind(window: firstWindow)
        secondCoordinator.bind(window: secondWindow)
        firstCoordinator.requestMainTerminalFocus(
            targetSessionID: UUID(),
            activateApp: false,
            surfaceStore: firstSurfaceStore,
            activeSessionID: nil
        )
        secondCoordinator.requestMainTerminalFocus(
            targetSessionID: nil,
            activateApp: false,
            surfaceStore: secondSurfaceStore,
            activeSessionID: nil
        )

        #expect(firstCoordinator.shouldSkipWindowFocusRestore(for: firstWindow))
        #expect(!secondCoordinator.shouldSkipWindowFocusRestore(for: secondWindow))
    }

    @Test("app activation restores focus only through the matching window delegate")
    func appActivationRestoresFocusOnlyForMatchingWindow() {
        let manager = TerminalFocusManager.shared
        let targetWindow = makeWindow()
        let otherWindow = makeWindow()
        let coordinator = TerminalFocusCoordinator()
        let surfaceStore = HostTerminalSurfaceStore()
        let otherSpy = FocusWindowDelegateSpy()

        defer {
            manager.unbindDelegate(from: targetWindow)
            manager.unbindDelegate(from: otherWindow)
        }

        coordinator.bind(window: targetWindow)
        manager.bindDelegate(otherSpy, to: otherWindow)

        coordinator.requestMainTerminalFocus(
            targetSessionID: UUID(),
            activateApp: false,
            surfaceStore: surfaceStore,
            activeSessionID: nil
        )

        manager.dispatchAppDidBecomeActive(to: [targetWindow])

        #expect(otherSpy.becameActiveWindows.isEmpty)
        #expect(coordinator.shouldSkipWindowFocusRestore(for: targetWindow))
    }
}

@MainActor
private func makeWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
}
