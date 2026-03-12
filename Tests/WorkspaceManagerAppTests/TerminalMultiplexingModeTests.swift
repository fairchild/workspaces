import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalMultiplexingMode")
struct TerminalMultiplexingModeTests {
    @Test("Resolve defaults to Ghostty-managed splits when unset")
    func resolveDefaultsToGhosttyManagedSplits() {
        let suiteName = "TerminalMultiplexingModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TerminalMultiplexingMode.resolve(from: defaults) == .ghosttyManagedSplits)
    }

    @Test("Resolve returns stored tmux mode")
    func resolveReturnsStoredTmuxMode() {
        let suiteName = "TerminalMultiplexingModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(TerminalMultiplexingMode.tmuxPerSession.rawValue, forKey: TerminalMultiplexingMode.storageKey)

        #expect(TerminalMultiplexingMode.resolve(from: defaults) == .tmuxPerSession)
    }
}
