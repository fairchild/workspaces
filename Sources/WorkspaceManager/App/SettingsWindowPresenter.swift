//
//  SettingsWindowPresenter.swift
//  WorkspaceManager
//
//  Shared bridge for opening the SwiftUI Settings scene from AppKit command paths.
//

import AppKit

@MainActor
enum SettingsWindowPresenter {
    @discardableResult
    static func open() -> Bool {
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return true
        }

        return NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
