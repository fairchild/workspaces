//
//  GhosttyCallbackUserdataTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("GhosttyCallbackUserdata")
@MainActor
struct GhosttyCallbackUserdataTests {
    @Test("manager(from:) returns nil for a nil userdata pointer")
    func managerNilForNilUserdata() {
        #expect(GhosttyCallbackUserdata.manager(from: nil) == nil)
    }

    @Test("surfaceView(from:) returns nil for a nil userdata pointer")
    func surfaceViewNilForNilUserdata() {
        let userdata: UnsafeMutableRawPointer? = nil
        #expect(GhosttyCallbackUserdata.surfaceView(from: userdata) == nil)
    }

    @Test("surfaceView(from:) round-trips passUnretained opaque pointers to the original view")
    func surfaceViewRoundTrip() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)
        let opaque = Unmanaged.passUnretained(view).toOpaque()

        let resolved = GhosttyCallbackUserdata.surfaceView(from: opaque)
        #expect(resolved === view)
    }

    @Test("surfaceView(from address:) returns nil for a nil address")
    func surfaceViewNilForNilAddress() {
        let address: UInt? = nil
        #expect(GhosttyCallbackUserdata.surfaceView(from: address) == nil)
    }

    @Test("surfaceView(from address:) round-trips bitPattern addresses to the original view")
    func surfaceViewFromAddressRoundTrip() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)
        let opaque = Unmanaged.passUnretained(view).toOpaque()
        let address = UInt(bitPattern: opaque)

        let resolved = GhosttyCallbackUserdata.surfaceView(from: address)
        #expect(resolved === view)
    }

    @Test("surfaceUserdata(from target:) returns nil when the target is an app target")
    func surfaceUserdataNilForAppTarget() {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        #expect(GhosttyCallbackUserdata.surfaceUserdata(from: target) == nil)
    }

    @Test("surfaceAddress(from target:) returns nil when the target is an app target")
    func surfaceAddressNilForAppTarget() {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        #expect(GhosttyCallbackUserdata.surfaceAddress(from: target) == nil)
    }
}
