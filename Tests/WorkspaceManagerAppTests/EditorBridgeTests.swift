//
//  EditorBridgeTests.swift
//  WorkspaceManagerAppTests
//
//  Codec + selection-mode behavior for the in-app editor bridge.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("Editor bridge messages")
struct EditorBridgeMessageTests {

    @Test("ready message decodes")
    func decodesReady() {
        #expect(EditorInboundMessage(body: ["type": "ready"]) == .ready)
    }

    @Test("save message decodes")
    func decodesSave() {
        #expect(EditorInboundMessage(body: ["type": "save"]) == .save)
    }

    @Test("dirty message decodes its boolean value")
    func decodesDirty() {
        #expect(EditorInboundMessage(body: ["type": "dirty", "value": true]) == .dirty(true))
        #expect(EditorInboundMessage(body: ["type": "dirty", "value": false]) == .dirty(false))
        // Missing value defaults to false rather than throwing.
        #expect(EditorInboundMessage(body: ["type": "dirty"]) == .dirty(false))
    }

    @Test("log and error map to log")
    func decodesLog() {
        #expect(EditorInboundMessage(body: ["type": "log", "message": "hi"]) == .log("hi"))
        #expect(EditorInboundMessage(body: ["type": "error", "message": "boom"]) == .log("boom"))
    }

    @Test("unknown and malformed bodies are tolerated")
    func decodesUnknown() {
        #expect(EditorInboundMessage(body: ["type": "nope"]) == .unknown("nope"))
        #expect(EditorInboundMessage(body: "not-a-dict") == .unknown("malformed"))
        #expect(EditorInboundMessage(body: ["no": "type"]) == .unknown("malformed"))
    }

    @Test("init payload encodes a JS-embeddable object")
    func initPayloadEncodes() throws {
        let payload = EditorInitPayload(
            mode: "review",
            head: "old\n",
            working: "new\n",
            language: "swift",
            theme: "dark",
            fontFamily: "Menlo",
            fontSize: 12
        )
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["mode"] as? String == "review")
        #expect(object?["language"] as? String == "swift")
        #expect(object?["theme"] as? String == "dark")
    }
}

@Suite("CodePreviewSelection mode")
struct CodePreviewSelectionModeTests {
    private let root = URL(fileURLWithPath: "/tmp/ws")

    @Test("selection defaults to read mode")
    func defaultsToRead() {
        let selection = CodePreviewSelection(rootURL: root, relativePath: "a.swift")
        #expect(selection.mode == .read)
    }

    @Test("with(mode:) preserves file identity but changes presentation")
    func withModePreservesFileIdentity() {
        let read = CodePreviewSelection(rootURL: root, relativePath: "a.swift")
        let editing = read.with(mode: .edit)
        #expect(editing.mode == .edit)
        #expect(editing.fileID == read.fileID)
        #expect(editing.id != read.id)
    }
}
