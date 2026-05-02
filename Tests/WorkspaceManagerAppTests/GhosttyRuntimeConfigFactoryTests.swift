//
//  GhosttyRuntimeConfigFactoryTests.swift
//  WorkspaceManagerAppTests
//

import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("GhosttyRuntimeConfigFactory")
struct GhosttyRuntimeConfigFactoryTests {
    @Test("Runtime config preserves callback userdata and selection clipboard support")
    func runtimeConfigPreservesUserdataAndSelectionClipboardSupport() {
        let userdata = UnsafeMutableRawPointer(bitPattern: 0x1234)
        let config = GhosttyRuntimeConfigFactory.make(userdata: userdata)

        #expect(config.userdata == userdata)
        #expect(config.supports_selection_clipboard == true)
    }

    @Test("Runtime config installs every callback used by libghostty")
    func runtimeConfigInstallsCallbacks() {
        let config = GhosttyRuntimeConfigFactory.make(userdata: nil)

        #expect(config.wakeup_cb != nil)
        #expect(config.action_cb != nil)
        #expect(config.read_clipboard_cb != nil)
        #expect(config.confirm_read_clipboard_cb != nil)
        #expect(config.write_clipboard_cb != nil)
        #expect(config.close_surface_cb != nil)
    }
}
