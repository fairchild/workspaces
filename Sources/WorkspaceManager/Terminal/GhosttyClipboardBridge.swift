//
//  GhosttyClipboardBridge.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

enum GhosttyClipboardBridge {
    static let textMIME = "text/plain"

    static func selectWriteText(
        from content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int
    ) -> String? {
        var preferredText: String?
        var fallbackText: String?

        for index in 0..<count {
            let item = content[index]
            guard let dataPointer = item.data else { continue }
            let data = String(
                decoding: UnsafeRawBufferPointer(start: dataPointer, count: item.len),
                as: UTF8.self
            )

            if fallbackText == nil {
                fallbackText = data
            }

            if let mimePointer = item.mime,
                String(cString: mimePointer) == textMIME
            {
                preferredText = data
                break
            }
        }

        return preferredText ?? fallbackText
    }

    /// Serves a Ghostty clipboard read. `requestedMIMEs` lists exactly the
    /// representations Ghostty can use, and this bridge serves only text, so a
    /// request without `text/plain` has nothing to answer. A `started` result
    /// promises the request is completed or denied with the same state pointer.
    static func read(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        requestedMIMEs: UnsafePointer<UnsafePointer<CChar>?>?,
        requestedMIMECount: Int,
        includeAvailableMIMEs: Bool
    ) -> ghostty_clipboard_read_result_e {
        let userdataAddress = GhosttyCallbackUserdata.address(from: userdata)
        let surfaceAddress = GhosttyThreadingBridge.runOnMainSync {
            GhosttyCallbackUserdata.surfaceAddress(from: userdataAddress)
        }
        let surface = GhosttyCallbackUserdata.pointer(from: surfaceAddress)
        guard let surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        guard requestsText(requestedMIMEs, count: requestedMIMECount) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        let value = GhosttyThreadingBridge.runOnMainSync {
            let pasteboard: NSPasteboard =
                switch location {
                case GHOSTTY_CLIPBOARD_STANDARD:
                    .general
                default:
                    .general
                }

            return pasteboard.string(forType: .string)
        }
        guard let value else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        complete(
            surface: surface,
            state: state,
            text: value,
            includeAvailableMIMEs: includeAvailableMIMEs
        )
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func requestsText(
        _ requestedMIMEs: UnsafePointer<UnsafePointer<CChar>?>?,
        count: Int
    ) -> Bool {
        guard let requestedMIMEs, count > 0 else { return false }

        for index in 0..<count {
            guard let mimePointer = requestedMIMEs[index] else { continue }
            if String(cString: mimePointer) == textMIME { return true }
        }

        return false
    }

    private static func complete(
        surface: ghostty_surface_t,
        state: UnsafeMutableRawPointer?,
        text: String,
        includeAvailableMIMEs: Bool
    ) {
        textMIME.withCString { mimePointer in
            text.withCString { dataPointer in
                let content = ghostty_clipboard_content_s(
                    mime: mimePointer,
                    data: dataPointer,
                    len: strlen(dataPointer)
                )
                let available: [UnsafePointer<CChar>?] = includeAvailableMIMEs ? [mimePointer] : []

                withUnsafePointer(to: content) { contentPointer in
                    available.withUnsafeBufferPointer { availableBuffer in
                        var request = ghostty_clipboard_complete_s(
                            contents: contentPointer,
                            contents_len: 1,
                            available: availableBuffer.baseAddress,
                            available_len: availableBuffer.count,
                            confirmed: false,
                            remember: false
                        )
                        ghostty_surface_complete_clipboard_request(surface, &request, state)
                    }
                }
            }
        }
    }

    /// Ghostty asks for confirmation before serving a read it considers unsafe
    /// (an OSC 52 sequence, say). This app has no confirmation UI, so the
    /// request is denied and nothing reaches the terminal.
    static func confirmRead(
        userdata: UnsafeMutableRawPointer?,
        state: UnsafeMutableRawPointer?
    ) {
        let userdataAddress = GhosttyCallbackUserdata.address(from: userdata)
        let surfaceAddress = GhosttyThreadingBridge.runOnMainSync {
            GhosttyCallbackUserdata.surfaceAddress(from: userdataAddress)
        }
        let surface = GhosttyCallbackUserdata.pointer(from: surfaceAddress)
        guard let surface else { return }

        ghostty_surface_deny_clipboard_request(surface, state)
    }

    static func write(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        let userdataAddress = GhosttyCallbackUserdata.address(from: userdata)
        let hasSurfaceView = GhosttyThreadingBridge.runOnMainSync {
            GhosttyCallbackUserdata.surfaceView(from: userdataAddress) != nil
        }

        guard location == GHOSTTY_CLIPBOARD_STANDARD,
            hasSurfaceView,
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
