//
//  GhosttyCallbackUserdata.swift
//  WorkspaceManager
//

import Foundation
import GhosttyKit

/// What a surface's libghostty userdata points at. A surface is freed on a later main-actor
/// turn than its view's `deinit` (`GhosttyAppManager.retireSurface`), so callbacks in between
/// must resolve to no view rather than a freed one, and the address must not be reused by a
/// new view while the old surface can still call back. Retained until after the surface's free.
final class GhosttySurfaceCallbackTarget: @unchecked Sendable {
    weak var view: GhosttySurfaceView?
}

enum GhosttyCallbackUserdata {
    static func address(from userdata: UnsafeMutableRawPointer?) -> UInt? {
        userdata.map { UInt(bitPattern: $0) }
    }

    static func pointer(from address: UInt?) -> UnsafeMutableRawPointer? {
        address.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
    }

    static func manager(from userdata: UnsafeMutableRawPointer?) -> GhosttyAppManager? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func manager(from address: UInt?) -> GhosttyAppManager? {
        manager(from: pointer(from: address))
    }

    static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackTarget>.fromOpaque(userdata).takeUnretainedValue().view
    }

    static func surfaceUserdata(from target: ghostty_target_s) -> UnsafeMutableRawPointer? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface
        else {
            return nil
        }

        return ghostty_surface_userdata(surface)
    }

    static func surfaceAddress(from target: ghostty_target_s) -> UInt? {
        surfaceUserdata(from: target).map { UInt(bitPattern: $0) }
    }

    @MainActor
    static func surfaceAddress(from userdata: UnsafeMutableRawPointer?) -> UInt? {
        surfaceView(from: userdata)?.surface.map { UInt(bitPattern: $0) }
    }

    @MainActor
    static func surfaceAddress(from address: UInt?) -> UInt? {
        surfaceAddress(from: pointer(from: address))
    }

    static func surfaceView(from address: UInt?) -> GhosttySurfaceView? {
        surfaceView(from: pointer(from: address))
    }

    static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        surfaceView(from: surfaceUserdata(from: target))
    }
}
