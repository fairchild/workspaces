//
//  AutomationFocus.swift
//  WorkspaceManagerCore
//
//  Wire types for `GET /v1/focus` (operator scope): a truthful report of the app's live
//  focus state. `focusPossible` is the explicit unavailable-is-not-unfocused marker: under
//  no-activate (or CI) the app is barred from acquiring focus on its own, so absent focus
//  is "unavailable", never evidence that focus restoration failed.
//

import Foundation

/// The app-level focus reading the MainActor enumerator produces before the controller
/// wraps it with the handle's capabilities. All fields are live AppKit truth: `appIsActive`
/// is `NSApp.isActive`, `keyWindowID` the key window's AppKit window number (the same
/// identity `window.read` lists), `firstResponderSurfaceID` the terminal surface owning the
/// key window's first responder (nil when focus rests outside any terminal surface), and
/// `focusPossible` whether the activation policy permits the app to take focus at all.
public struct AutomationFocusState: Sendable, Equatable {
    public let appIsActive: Bool
    public let keyWindowID: String?
    public let firstResponderSurfaceID: String?
    public let focusPossible: Bool

    public init(
        appIsActive: Bool,
        keyWindowID: String?,
        firstResponderSurfaceID: String?,
        focusPossible: Bool
    ) {
        self.appIsActive = appIsActive
        self.keyWindowID = keyWindowID
        self.firstResponderSurfaceID = firstResponderSurfaceID
        self.focusPossible = focusPossible
    }
}

/// Response for `GET /v1/focus` (`window.read`, operator scope). `focusPossible: false`
/// means the launch runs under a no-activate policy (shared desktop or CI): the app never
/// steals focus, so `appIsActive`/`keyWindowID`/`firstResponderSurfaceID` can only be
/// non-empty if the user focused the app themselves. Callers asserting on focus must branch
/// on `focusPossible` first — a null surface with `focusPossible: false` is "unavailable
/// under this launch policy", not "nothing is focused".
public struct AutomationFocusResult: Codable, Sendable, Equatable {
    public let appIsActive: Bool
    public let keyWindowID: String?
    public let firstResponderSurfaceID: String?
    public let focusPossible: Bool
    public let system: AutomationSystemDescriptor

    public init(
        state: AutomationFocusState,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.appIsActive = state.appIsActive
        self.keyWindowID = state.keyWindowID
        self.firstResponderSurfaceID = state.firstResponderSurfaceID
        self.focusPossible = state.focusPossible
        self.system = system
    }
}
