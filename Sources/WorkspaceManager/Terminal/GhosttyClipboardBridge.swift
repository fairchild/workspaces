//
//  GhosttyClipboardBridge.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

enum GhosttyClipboardBridge {
    static func selectWriteText(
        from content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int
    ) -> String? {
        var preferredText: String?
        var fallbackText: String?

        for index in 0..<count {
            let item = content[index]
            guard let dataPointer = item.data else { continue }
            let data = String(cString: dataPointer)

            if fallbackText == nil {
                fallbackText = data
            }

            if let mimePointer = item.mime,
                String(cString: mimePointer) == "text/plain"
            {
                preferredText = data
                break
            }
        }

        return preferredText ?? fallbackText
    }

    static func read(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        let surfaceAddress = GhosttyThreadingBridge.runOnMainSync {
            GhosttyCallbackUserdata.surfaceView(from: userdata)?.surface.map { UInt(bitPattern: $0) }
        }
        let surface = surfaceAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        guard let surface else { return }

        let value = GhosttyThreadingBridge.runOnMainSync {
            let pasteboard: NSPasteboard =
                switch location {
                case GHOSTTY_CLIPBOARD_STANDARD:
                    .general
                default:
                    .general
                }

            return pasteboard.string(forType: .string) ?? ""
        }
        value.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
    }

    static func confirmRead(
        userdata: UnsafeMutableRawPointer?,
        state: UnsafeMutableRawPointer?
    ) {
        let surfaceAddress = GhosttyThreadingBridge.runOnMainSync {
            GhosttyCallbackUserdata.surfaceView(from: userdata)?.surface.map { UInt(bitPattern: $0) }
        }
        let surface = surfaceAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        guard let surface else { return }

        "".withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
    }

    static func write(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard GhosttyCallbackUserdata.surfaceView(from: userdata) != nil,
            location == GHOSTTY_CLIPBOARD_STANDARD,
            let content,
            len > 0,
            let value = selectWriteText(from: content, count: len)
        else {
            return
        }

        GhosttyThreadingBridge.runOnMainAsync {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }
}
