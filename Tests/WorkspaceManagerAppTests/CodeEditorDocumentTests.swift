import Foundation
import Testing

@testable import WorkspaceManager

@Suite("Code editor document safety")
struct CodeEditorDocumentTests {
    @Test("UTF-8 text files are editable")
    func utf8TextFilesAreEditable() {
        let payload = CodePreviewPayload(
            text: "let value = 1\n",
            language: .swift,
            spans: [],
            isTruncated: false
        )

        let document = CodeEditorDocument(payload: payload)

        #expect(document.canEdit)
        #expect(!document.isDirty)
        #expect(document.originalText == "let value = 1\n")
        #expect(document.currentText == "let value = 1\n")
    }

    @Test("Empty UTF-8 files are editable")
    func emptyFilesAreEditable() {
        let payload = CodePreviewPayload(
            text: "",
            language: .plain,
            spans: [],
            isTruncated: false
        )

        let document = CodeEditorDocument(payload: payload)

        #expect(document.canEdit)
        #expect(!document.isDirty)
    }

    @Test("In-memory edits mark the document dirty")
    func inMemoryEditsMarkDocumentDirty() {
        let payload = CodePreviewPayload(
            text: "before\n",
            language: .plain,
            spans: [],
            isTruncated: false
        )

        var document = CodeEditorDocument(payload: payload)
        document.currentText = "after\n"

        #expect(document.isDirty)
        #expect(document.originalText == "before\n")
        #expect(document.currentText == "after\n")
    }

    @Test("Truncated files are read-only")
    func truncatedFilesAreReadOnly() {
        let payload = CodePreviewPayload(
            text: "prefix",
            language: .plain,
            spans: [],
            isTruncated: true
        )

        let document = CodeEditorDocument(payload: payload)

        #expect(!document.canEdit)
        #expect(document.readOnlyReason?.contains("too large") == true)
    }

    @Test("Loader marks over-limit files truncated")
    func loaderMarksOverLimitFilesTruncated() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("large.txt")
        let data = Data(repeating: 97, count: CodePreviewLoader.maxPreviewBytes + 1)
        try data.write(to: fileURL)

        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        let document = CodeEditorDocument(payload: payload)

        #expect(payload.isTruncated)
        #expect(!document.canEdit)
    }

    @Test("Loader rejects unsupported text encoding")
    func loaderRejectsUnsupportedTextEncoding() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("latin1.txt")
        try Data([0xE9]).write(to: fileURL)

        do {
            _ = try await CodePreviewLoader.load(fileURL: fileURL)
            Issue.record("Expected unsupported encoding error")
        } catch let error as CodePreviewError {
            #expect(error == .unsupportedEncoding)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeEditorDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
