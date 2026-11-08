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
    @Test("address(from:) returns nil for nil userdata")
    func addressNilForNilUserdata() {
        #expect(GhosttyCallbackUserdata.address(from: nil) == nil)
    }

    @Test("pointer(from:) returns nil for nil address")
    func pointerNilForNilAddress() {
        #expect(GhosttyCallbackUserdata.pointer(from: nil) == nil)
    }

    @Test("address and pointer round-trip an opaque userdata pointer")
    func userdataAddressRoundTrip() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)
        let opaque = Unmanaged.passUnretained(view).toOpaque()

        let address = GhosttyCallbackUserdata.address(from: opaque)

        #expect(address == UInt(bitPattern: opaque))
        #expect(GhosttyCallbackUserdata.pointer(from: address) == opaque)
    }

    @Test("manager(from:) returns nil for a nil userdata pointer")
    func managerNilForNilUserdata() {
        #expect(GhosttyCallbackUserdata.manager(from: nil as UnsafeMutableRawPointer?) == nil)
    }

    @Test("manager(from address:) returns nil for a nil address")
    func managerNilForNilAddress() {
        let address: UInt? = nil
        #expect(GhosttyCallbackUserdata.manager(from: address) == nil)
    }

    @Test("surfaceView(from:) returns nil for a nil userdata pointer")
    func surfaceViewNilForNilUserdata() {
        let userdata: UnsafeMutableRawPointer? = nil
        #expect(GhosttyCallbackUserdata.surfaceView(from: userdata) == nil)
    }

    @Test("surfaceView(from:) resolves a view's callback userdata to that view")
    func surfaceViewRoundTrip() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)

        let resolved = GhosttyCallbackUserdata.surfaceView(from: view.callbackUserdata)
        #expect(resolved === view)
    }

    @Test("A released view's callback userdata resolves to no view while its surface waits to be freed")
    func surfaceViewNilAfterViewReleased() {
        let userdata: UnsafeMutableRawPointer = autoreleasepool {
            let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)
            _ = Unmanaged<GhosttySurfaceCallbackTarget>.fromOpaque(view.callbackUserdata).retain()
            return view.callbackUserdata
        }
        defer { Unmanaged<GhosttySurfaceCallbackTarget>.fromOpaque(userdata).release() }

        let resolvesToView = GhosttyCallbackUserdata.surfaceView(from: userdata) != nil
        #expect(GhosttyAppManager.shared.retiredSurfaceCount > 0)
        #expect(!resolvesToView)
    }

    @Test("surfaceView(from address:) returns nil for a nil address")
    func surfaceViewNilForNilAddress() {
        let address: UInt? = nil
        #expect(GhosttyCallbackUserdata.surfaceView(from: address) == nil)
    }

    @Test("surfaceView(from address:) resolves a view's callback userdata address to that view")
    func surfaceViewFromAddressRoundTrip() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)
        let address = UInt(bitPattern: view.callbackUserdata)

        let resolved = GhosttyCallbackUserdata.surfaceView(from: address)
        #expect(resolved === view)
    }

    @Test("surfaceAddress(from userdata:) returns nil for nil userdata")
    func surfaceAddressFromNilUserdata() {
        #expect(GhosttyCallbackUserdata.surfaceAddress(from: nil as UnsafeMutableRawPointer?) == nil)
    }

    @Test("surfaceAddress(from address:) returns nil for a nil address")
    func surfaceAddressFromNilAddress() {
        let address: UInt? = nil
        #expect(GhosttyCallbackUserdata.surfaceAddress(from: address) == nil)
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
