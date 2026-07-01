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

    @Test("Loaded UTF-8 files can save once dirty")
    func loadedUTF8FilesCanSaveOnceDirty() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("note.txt")
        try Data("before\n".utf8).write(to: fileURL)

        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        var document = CodeEditorDocument(payload: payload)
        document.currentText = "after\n"

        #expect(document.canSave)

        let savedSnapshot = try CodeEditorSaveService.saveSynchronously(
            CodeEditorSaveRequest(
                rootURL: directory,
                relativePath: "note.txt",
                editedText: document.currentText,
                snapshot: document.fileSnapshot
            )
        )
        document.markSaved(snapshot: savedSnapshot)

        #expect(!document.isDirty)
        #expect(String(data: try Data(contentsOf: fileURL), encoding: .utf8) == "after\n")
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
        #expect(!document.canSave)
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

    @Test("Save preserves CRLF line endings, trailing newline state, and mode bits")
    func savePreservesCRLFLineEndingsTrailingNewlineStateAndModeBits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("script.txt")
        try Data("one\r\ntwo".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fileURL.path)

        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        let snapshot = try CodeEditorSaveService.saveSynchronously(
            CodeEditorSaveRequest(
                rootURL: directory,
                relativePath: "script.txt",
                editedText: "one\ntwo\nthree",
                snapshot: payload.fileSnapshot
            )
        )

        #expect(String(data: try Data(contentsOf: fileURL), encoding: .utf8) == "one\r\ntwo\r\nthree")
        #expect(snapshot.posixMode & 0o777 == 0o755)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o777 == 0o755)
    }

    @Test("Save refuses changed-on-disk files")
    func saveRefusesChangedOnDiskFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("conflict.txt")
        try Data("original\n".utf8).write(to: fileURL)
        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        try Data("external\n".utf8).write(to: fileURL)

        do {
            _ = try CodeEditorSaveService.saveSynchronously(
                CodeEditorSaveRequest(
                    rootURL: directory,
                    relativePath: "conflict.txt",
                    editedText: "editor\n",
                    snapshot: payload.fileSnapshot
                )
            )
            Issue.record("Expected changed-on-disk refusal")
        } catch let error as CodeEditorSaveError {
            #expect(error == .changedOnDisk)
        }

        #expect(String(data: try Data(contentsOf: fileURL), encoding: .utf8) == "external\n")
    }

    @Test("Save refuses relative path escapes")
    func saveRefusesRelativePathEscapes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("inside.txt")
        try Data("inside\n".utf8).write(to: fileURL)
        let snapshot = try CodeEditorFileSnapshot.make(fileURL: fileURL, data: Data("inside\n".utf8))

        do {
            _ = try CodeEditorSaveService.saveSynchronously(
                CodeEditorSaveRequest(
                    rootURL: directory,
                    relativePath: "../outside.txt",
                    editedText: "escape\n",
                    snapshot: snapshot
                )
            )
            Issue.record("Expected path escape refusal")
        } catch let error as CodeEditorSaveError {
            #expect(error == .invalidRelativePath)
        }
    }

    @Test("Save refuses symlink targets")
    func saveRefusesSymlinkTargets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetURL = directory.appendingPathComponent("target.txt")
        let linkURL = directory.appendingPathComponent("link.txt")
        try Data("target\n".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let payload = try await CodePreviewLoader.load(fileURL: linkURL)
        let document = CodeEditorDocument(payload: payload)
        #expect(!document.canEdit)
        #expect(document.readOnlyReason?.contains("Symbolic links") == true)

        do {
            _ = try CodeEditorSaveService.saveSynchronously(
                CodeEditorSaveRequest(
                    rootURL: directory,
                    relativePath: "link.txt",
                    editedText: "editor\n",
                    snapshot: payload.fileSnapshot
                )
            )
            Issue.record("Expected symlink refusal")
        } catch let error as CodeEditorSaveError {
            #expect(error == .symlinkRefused)
        }

        #expect(String(data: try Data(contentsOf: targetURL), encoding: .utf8) == "target\n")
    }

    @Test("Save refuses symlink parent escapes")
    func saveRefusesSymlinkParentEscapes() throws {
        let directory = try temporaryDirectory()
        let outsideDirectory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        let linkDirectory = directory.appendingPathComponent("linked")
        let outsideFileURL = outsideDirectory.appendingPathComponent("outside.txt")
        try Data("outside\n".utf8).write(to: outsideFileURL)
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: outsideDirectory)
        let snapshot = try CodeEditorFileSnapshot.make(fileURL: outsideFileURL, data: Data("outside\n".utf8))

        do {
            _ = try CodeEditorSaveService.saveSynchronously(
                CodeEditorSaveRequest(
                    rootURL: directory,
                    relativePath: "linked/outside.txt",
                    editedText: "escape\n",
                    snapshot: snapshot
                )
            )
            Issue.record("Expected resolved path escape refusal")
        } catch let error as CodeEditorSaveError {
            #expect(error == .pathEscapesRoot)
        }

        #expect(String(data: try Data(contentsOf: outsideFileURL), encoding: .utf8) == "outside\n")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeEditorDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
