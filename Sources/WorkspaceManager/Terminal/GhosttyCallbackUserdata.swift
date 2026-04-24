//
//  GhosttyCallbackUserdata.swift
//  WorkspaceManager
//

import Foundation
import GhosttyKit

enum GhosttyCallbackUserdata {
    static func manager(from userdata: UnsafeMutableRawPointer?) -> GhosttyAppManager? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
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

    static func surfaceView(from address: UInt?) -> GhosttySurfaceView? {
        guard let address else { return nil }
        return surfaceView(from: UnsafeMutableRawPointer(bitPattern: address))
    }

    static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        surfaceView(from: surfaceUserdata(from: target))
    }
}
