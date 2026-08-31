//
//  MobilePairingFeature.swift
//  WorkspaceManager
//
//  The master switch for mobile pairing / remote connectivity. Every desktop
//  integration point checks this one gate, so disabling it removes the whole
//  remote surface: no pairing window, no tailnet-origin resolution, and the
//  embedded web-next child receives no extra allowlisted origins — leaving it
//  loopback-only, byte-identical to a build without the feature.
//
//  Disable, in precedence order:
//    1. launch argument   --disable-mobile-pairing
//    2. environment       WORKSPACES_DISABLE_MOBILE_PAIRING=1
//    3. defaults          mobilePairingEnabled = false   (MDM-manageable)
//  Forks that want it gone entirely: delete Sources/WorkspaceManager/MobilePairing/
//  and the integration points listed in docs/development/mobile-pairing-isolation.md.
//

import Foundation
import SwiftUI
import WorkspaceManagerCore

enum MobilePairingFeature {
    static let defaultsKey = "mobilePairingEnabled"

    static var isEnabled: Bool {
        if CommandLine.arguments.contains("--disable-mobile-pairing") { return false }
        if ProcessInfo.processInfo.environment["WORKSPACES_DISABLE_MOBILE_PAIRING"] == "1" {
            return false
        }
        if LaunchPreferences.defaults.object(forKey: defaultsKey) != nil {
            return LaunchPreferences.defaults.bool(forKey: defaultsKey)
        }
        return true
    }
}

/// What the pairing window shows when the feature is switched off: an honest
/// policy notice, with nothing pairing-related initialized behind it.
struct MobilePairingDisabledView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Mobile pairing is disabled on this Mac.")
                .font(.callout)
            Text("Enable with the mobilePairingEnabled default, or remove the disable flag.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(24)
        .frame(width: 360)
    }
}
