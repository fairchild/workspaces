import AppKit
import Foundation

/// Process-wide gate for `NSApp.activate(ignoringOtherApps:)` calls.
///
/// Two environment signals suppress activation:
/// - `CI=*` — running under continuous integration. The AppDelegate also flips the
///   activation policy to `.accessory`, but this policy still blocks runtime
///   activate calls for clarity and testability.
/// - `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` (or `true`/`yes`/`on`) — shared-desktop
///   mode. The app keeps its `.regular` policy and dock presence but never steals
///   foreground focus, on launch *or* during runtime.
///
/// All call sites that would otherwise call `NSApp.activate` route through this
/// policy. See `docs/development/shortcut-routing.md` and the `--no-activate`
/// option in `scripts/launch-dev.sh`.
@MainActor
public struct AppActivationPolicy {
    public let allowsActivation: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let isCI = environment["CI"] != nil
        let noActivate = Self.parseBool(environment["WORKSPACES_NO_ACTIVATE_ON_LAUNCH"])
        self.allowsActivation = !isCI && !noActivate
    }

    /// Activate the app, but only if the policy allows. Use at launch.
    public func activateIfAllowed() {
        guard allowsActivation else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Activate the app and bring the front-most window to key, but only if
    /// the policy allows. Use for runtime focus restoration paths.
    public func activateAndFocusFrontWindowIfAllowed() {
        guard allowsActivation else { return }
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)
    }

    private static func parseBool(_ value: String?) -> Bool {
        guard let raw = value else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    public static let shared = AppActivationPolicy()
}
