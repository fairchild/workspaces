//
//  UserNotificationsAvailability.swift
//  WorkspaceManagerCore
//
//  The one check standing between an unbundled binary and an uncatchable
//  exception. `UNUserNotificationCenter.current()` raises
//  NSInternalInconsistencyException ("bundleProxyForCurrentProcess is nil") when
//  the main bundle is not a code-signed application; it propagates to the
//  runloop and terminates the app. Every raw `swift run` launch is that case,
//  which is why this is checked before any call and why it now lives beside the
//  second caller rather than private to the first.
//

import Foundation

public enum UserNotificationsAvailability {
    /// True only inside a real `.app` bundle the notification framework can
    /// resolve. A raw debug binary's `bundleURL` points at the executable's
    /// parent directory, which has no `.app` extension.
    public static let isAvailable: Bool = {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }()
}
