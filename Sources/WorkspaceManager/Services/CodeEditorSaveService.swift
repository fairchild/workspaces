//
//  CodeEditorSaveService.swift
//  WorkspaceManager
//
//  Safe disk-write pipeline for the native small-file editor.
//

import Darwin
import Foundation

enum CodeEditorLineEndingStyle: Equatable, Sendable {
    case lf
    case crlf
    case cr
    case mixed

    init(text: String) {
        let bytes = Array(text.utf8)
        var index = 0
        var sawLF = false
        var sawCRLF = false
        var sawCR = false

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                let nextIndex = index + 1
                if nextIndex < bytes.count, bytes[nextIndex] == 0x0A {
                    sawCRLF = true
                    index += 2
                } else {
                    sawCR = true
                    index += 1
                }
            } else if byte == 0x0A {
                sawLF = true
                index += 1
            } else {
                index += 1
            }
        }

        switch (sawLF, sawCRLF, sawCR) {
        case (false, true, false):
            self = .crlf
        case (false, false, true):
            self = .cr
        case (false, false, false), (true, false, false):
            self = .lf
        default:
            self = .mixed
        }
    }
}

struct CodeEditorFileSnapshot: Equatable, Sendable {
    let byteCount: Int
    let contentHash: UInt64
    let posixMode: Int
    let lineEndingStyle: CodeEditorLineEndingStyle

    static func make(fileURL: URL, data: Data) throws -> CodeEditorFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let text = String(decoding: data, as: UTF8.self)
        return CodeEditorFileSnapshot(
            byteCount: data.count,
            contentHash: stableContentHash(data),
            posixMode: mode,
            lineEndingStyle: CodeEditorLineEndingStyle(text: text)
        )
    }

    func matches(fileURL: URL, data: Data) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        return byteCount == data.count
            && contentHash == Self.stableContentHash(data)
            && posixMode == mode
    }

    private static func stableContentHash(_ data: Data) -> UInt64 {
        data.reduce(0xcbf2_9ce4_8422_2325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
        }
    }
}

struct CodeEditorSaveRequest: Sendable {
    let rootURL: URL
    let relativePath: String
    let editedText: String
    let snapshot: CodeEditorFileSnapshot?
}

enum CodeEditorSaveError: LocalizedError, Equatable {
    case missingSnapshot
    case invalidRelativePath
    case pathEscapesRoot
    case symlinkRefused
    case changedOnDisk
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSnapshot:
            return "Save is unavailable because this file was not loaded with a safety snapshot."
        case .invalidRelativePath:
            return "Save refused because the selected path is not a relative file path."
        case .pathEscapesRoot:
            return "Save refused because the selected path resolves outside the workspace root."
        case .symlinkRefused:
            return "Save refused because the selected file is a symbolic link."
        case .changedOnDisk:
            return "This file changed on disk. Reload it before saving so you do not overwrite newer changes."
        case .readFailed(let message):
            return "Could not read the latest file contents before saving: \(message)"
        case .writeFailed(let message):
            return "Could not save this file: \(message)"
        }
    }
}

enum CodeEditorSaveService {
    static func save(_ request: CodeEditorSaveRequest) async throws -> CodeEditorFileSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try saveSynchronously(request)
        }
        .value
    }

    static func saveSynchronously(_ request: CodeEditorSaveRequest) throws -> CodeEditorFileSnapshot {
        guard let snapshot = request.snapshot else {
            throw CodeEditorSaveError.missingSnapshot
        }

        let lexicalTargetURL = try lexicalFileURL(rootURL: request.rootURL, relativePath: request.relativePath)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: lexicalTargetURL.path)) == nil else {
            throw CodeEditorSaveError.symlinkRefused
        }

        let targetURL = try containedFileURL(rootURL: request.rootURL, relativePath: request.relativePath)

        let currentData: Data
        do {
            currentData = try Data(contentsOf: targetURL)
        } catch {
            throw CodeEditorSaveError.readFailed(error.localizedDescription)
        }

        guard try snapshot.matches(fileURL: targetURL, data: currentData) else {
            throw CodeEditorSaveError.changedOnDisk
        }

        let replacementData = normalizedData(
            from: request.editedText,
            lineEndingStyle: snapshot.lineEndingStyle
        )

        let temporaryURL =
            targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).workspaces-save-\(UUID().uuidString).tmp")

        do {
            try replacementData.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: snapshot.posixMode)],
                ofItemAtPath: temporaryURL.path
            )

            guard Darwin.rename(temporaryURL.path, targetURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let savedData = try Data(contentsOf: targetURL)
            return try CodeEditorFileSnapshot.make(fileURL: targetURL, data: savedData)
        } catch let error as CodeEditorSaveError {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw CodeEditorSaveError.writeFailed(error.localizedDescription)
        }
    }

    static func containedFileURL(rootURL: URL, relativePath: String) throws -> URL {
        let lexicalTarget = try lexicalFileURL(rootURL: rootURL, relativePath: relativePath)

        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let target = lexicalTarget.resolvingSymlinksInPath()

        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw CodeEditorSaveError.pathEscapesRoot
        }

        return target
    }

    private static func lexicalFileURL(rootURL: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." })
        else {
            throw CodeEditorSaveError.invalidRelativePath
        }

        return rootURL.appendingPathComponent(relativePath).standardizedFileURL
    }

    private static func normalizedData(from text: String, lineEndingStyle: CodeEditorLineEndingStyle) -> Data {
        let outputText: String
        switch lineEndingStyle {
        case .lf, .mixed:
            outputText = text
        case .crlf:
            let normalized =
                text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            outputText = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr:
            let normalized =
                text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            outputText = normalized.replacingOccurrences(of: "\n", with: "\r")
        }

        return Data(outputText.utf8)
    }
}
