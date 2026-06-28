//
//  EditorBridge.swift
//  WorkspaceManager
//
//  Message contract between the embedded CodeMirror bundle and the native app.
//  Swift pushes init/theme via `window.__editorHost.*`; the bundle reports back over
//  the `editor` script-message handler. Kept free of WebKit types so the codec is unit-testable.
//

import Foundation

/// Payload sent to the bundle to (re)build the editor for a file.
struct EditorInitPayload: Encodable, Equatable {
    /// "review" renders an editable unified diff against `head`; "edit" is a plain editor.
    let mode: String
    let head: String
    let working: String
    let language: String
    let theme: String
    let fontFamily: String
    let fontSize: Double
}

/// Live appearance update (light/dark + font) without rebuilding the document.
struct EditorThemePayload: Encodable, Equatable {
    let theme: String
    let fontFamily: String
    let fontSize: Double
}

/// A message received from the editor bundle.
enum EditorInboundMessage: Equatable, Sendable {
    case ready
    case dirty(Bool)
    case save
    case log(String)
    case unknown(String)

    init(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else {
            self = .unknown("malformed")
            return
        }
        switch type {
        case "ready":
            self = .ready
        case "save":
            self = .save
        case "dirty":
            self = .dirty((dict["value"] as? Bool) ?? false)
        case "log", "error":
            self = .log((dict["message"] as? String) ?? "")
        default:
            self = .unknown(type)
        }
    }
}

enum EditorDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["WORKSPACES_DEBUG_EDITOR"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("[Editor] %@", message())
    }
}
