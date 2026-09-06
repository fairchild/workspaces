//
//  GhosttyClipboardBridgeTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("GhosttyClipboardBridge.selectWriteText")
struct GhosttyClipboardBridgeSelectWriteTextTests {
    @Test("Returns the single entry when only one item is provided")
    func singleEntry() {
        withContent([(mime: "text/plain", data: "hello")]) { buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == "hello")
        }
    }

    @Test("Prefers the text/plain entry over earlier non-matching MIME types")
    func prefersTextPlainOverOtherMIME() {
        withContent([
            (mime: "text/html", data: "<b>hi</b>"),
            (mime: "text/plain", data: "plain hi"),
        ]) { buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == "plain hi")
        }
    }

    @Test("Falls back to the first entry when no text/plain is present")
    func fallsBackToFirstEntry() {
        withContent([
            (mime: "text/html", data: "<b>first</b>"),
            (mime: "application/json", data: "{}"),
        ]) { buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == "<b>first</b>")
        }
    }

    @Test("Falls back to the first entry when MIME is nil")
    func fallsBackWhenMIMEIsNil() {
        withContent([(mime: nil, data: "no-mime")]) { buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == "no-mime")
        }
    }

    @Test("Skips entries with nil data and uses the next valid one")
    func skipsNilData() {
        withContent([(mime: "text/plain", data: nil), (mime: "text/plain", data: "later")]) {
            buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == "later")
        }
    }

    @Test("Returns nil when all entries have nil data")
    func returnsNilWhenAllEntriesAreEmpty() {
        withContent([(mime: "text/plain", data: nil), (mime: "text/html", data: nil)]) {
            buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == nil)
        }
    }

    @Test("Reads exactly the declared length, not to the next null byte")
    func honorsDeclaredLength() {
        withContent([(mime: "text/plain", data: "visible")], truncatedTo: 3) { buffer, count in
            #expect(GhosttyClipboardBridge.selectWriteText(from: buffer, count: count) == "vis")
        }
    }
}

@Suite("GhosttyClipboardBridge.requestsText")
struct GhosttyClipboardBridgeRequestsTextTests {
    @Test("Accepts a request listing text/plain among other types")
    func acceptsTextPlain() {
        withMIMEs(["image/png", "text/plain"]) { buffer, count in
            #expect(GhosttyClipboardBridge.requestsText(buffer, count: count))
        }
    }

    @Test("Rejects a request for types this bridge cannot serve")
    func rejectsUnservableTypes() {
        withMIMEs(["image/png", "text/html"]) { buffer, count in
            #expect(!GhosttyClipboardBridge.requestsText(buffer, count: count))
        }
    }

    @Test("Rejects an empty request")
    func rejectsEmptyRequest() {
        withMIMEs([]) { buffer, count in
            #expect(!GhosttyClipboardBridge.requestsText(buffer, count: count))
        }
    }

    @Test("Rejects a null request list")
    func rejectsNullList() {
        #expect(!GhosttyClipboardBridge.requestsText(nil, count: 3))
    }
}

private func withMIMEs(
    _ mimes: [String],
    body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void
) {
    var buffers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in buffers { pointer?.deallocate() } }

    let pointers: [UnsafePointer<CChar>?] = mimes.map { mime in
        let buffer = copyCString(mime)
        buffers.append(buffer)
        return UnsafePointer(buffer)
    }

    pointers.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress, mimes.count)
    }
}

private typealias ClipboardItem = (mime: String?, data: String?)

private func withContent(
    _ items: [ClipboardItem],
    truncatedTo length: Int? = nil,
    body: (UnsafePointer<ghostty_clipboard_content_s>, Int) -> Void
) {
    var mimeBuffers: [UnsafeMutablePointer<CChar>?] = []
    var dataBuffers: [UnsafeMutablePointer<CChar>?] = []
    defer {
        for pointer in mimeBuffers { pointer?.deallocate() }
        for pointer in dataBuffers { pointer?.deallocate() }
    }

    let content: [ghostty_clipboard_content_s] = items.map { item in
        var value = ghostty_clipboard_content_s()
        if let mime = item.mime {
            let buffer = copyCString(mime)
            mimeBuffers.append(buffer)
            value.mime = UnsafePointer(buffer)
        } else {
            mimeBuffers.append(nil)
            value.mime = nil
        }
        if let data = item.data {
            let buffer = copyCString(data)
            dataBuffers.append(buffer)
            value.data = UnsafePointer(buffer)
            value.len = length ?? data.utf8.count
        } else {
            dataBuffers.append(nil)
            value.data = nil
            value.len = 0
        }
        return value
    }

    content.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        body(base, items.count)
    }
}

private func copyCString(_ string: String) -> UnsafeMutablePointer<CChar> {
    let utf8 = Array(string.utf8CString)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
    buffer.initialize(from: utf8, count: utf8.count)
    return buffer
}
