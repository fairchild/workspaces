//
//  GhosttyDroppedContentFormatter.swift
//  WorkspaceManager
//

import AppKit
import Foundation

/// Formats drag-and-drop pasteboard payloads for insertion into a live terminal.
/// File paths and URLs are escaped for shell editing; plain strings are passed
/// through so dragging selected command text keeps its original contents.
enum GhosttyDroppedContentFormatter {
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .string,
        .fileURL,
        .URL,
    ]

    static func accepts(types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return !Set(types).isDisjoint(with: pasteboardTypes)
    }

    static func content(from pasteboard: NSPasteboard) -> String? {
        if let url = pasteboard.string(forType: .URL) {
            return shellEscape(url)
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
            let content = content(forURLs: urls)
        {
            return content
        }

        return pasteboard.string(forType: .string)
    }

    static func content(forURLs urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        return
            urls
            .map { shellEscape($0.isFileURL ? $0.path : $0.absoluteString) }
            .joined(separator: " ")
    }

    static func shellEscape(_ value: String) -> String {
        var result = value
        for character in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(
                of: String(character),
                with: "\\\(character)"
            )
        }
        return result
    }
}
