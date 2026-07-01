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

    @Test("Saving writes UTF-8 text and clears dirty state")
    func savingWritesTextAndClearsDirtyState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("notes.md")
        try Data("before\n".utf8).write(to: fileURL)

        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        var document = CodeEditorDocument(payload: payload)
        document.currentText = "after\n"

        #expect(document.canSave)

        try document.save(rootURL: directory, relativePath: "notes.md")

        #expect(String(data: try Data(contentsOf: fileURL), encoding: .utf8) == "after\n")
        #expect(!document.isDirty)
        #expect(document.originalText == "after\n")
    }

    @Test("Saving refuses to overwrite files changed on disk")
    func savingRefusesStaleDiskContents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("notes.md")
        try Data("before\n".utf8).write(to: fileURL)

        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        var document = CodeEditorDocument(payload: payload)
        document.currentText = "after\n"
        try Data("external\n".utf8).write(to: fileURL)

        do {
            try document.save(rootURL: directory, relativePath: "notes.md")
            Issue.record("Expected changed-on-disk save error")
        } catch let error as CodeEditorSaveError {
            #expect(error == .changedOnDisk)
        }

        #expect(String(data: try Data(contentsOf: fileURL), encoding: .utf8) == "external\n")
        #expect(document.isDirty)
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

    @Test("Saved baseline updates without discarding newer in-memory edits")
    func savedBaselineUpdatesWithoutDiscardingNewerInMemoryEdits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("notes.md")
        try Data("before\n".utf8).write(to: fileURL)

        let payload = try await CodePreviewLoader.load(fileURL: fileURL)
        var document = CodeEditorDocument(payload: payload)
        let savedText = "saved\n"
        document.currentText = savedText

        let snapshot = try CodeEditorSaveService.saveSynchronously(
            CodeEditorSaveRequest(
                rootURL: directory,
                relativePath: "notes.md",
                editedText: savedText,
                snapshot: document.fileSnapshot
            )
        )

        document.currentText = "newer\n"
        document.markSaved(text: savedText, snapshot: snapshot)

        #expect(document.originalText == savedText)
        #expect(document.currentText == "newer\n")
        #expect(document.isDirty)
    }

    @Test("Save refuses relative path escapes")
    func saveRefusesRelativePathEscapes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("inside.txt")
        try Data("inside\n".utf8).write(to: fileURL)
        let payload = try await CodePreviewLoader.load(fileURL: fileURL)

        do {
            _ = try CodeEditorSaveService.saveSynchronously(
                CodeEditorSaveRequest(
                    rootURL: directory,
                    relativePath: "../outside.txt",
                    editedText: "escape\n",
                    snapshot: payload.fileSnapshot
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
        #expect(!document.canSave)
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
    func saveRefusesSymlinkParentEscapes() async throws {
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
