import AppKit
import Foundation

enum ExternalEditorID: String, CaseIterable, Identifiable, Sendable {
    case zed

    var id: String { rawValue }
}

struct ExternalEditorDescriptor: Identifiable, Hashable, Sendable {
    let id: ExternalEditorID
    let displayName: String
}

enum ExternalEditorError: LocalizedError, Equatable {
    case projectRootNotFound(URL)
    case fileNotFound(URL)
    case fileOutsideProject(projectRoot: URL, file: URL)
    case editorNotInstalled(ExternalEditorID)
    case editorCLIUnavailable(ExternalEditorID, path: String)
    case launchFailed(ExternalEditorID, reason: String)

    var errorDescription: String? {
        switch self {
        case .projectRootNotFound(let url):
            return "Project folder not found: \(url.path)"
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .fileOutsideProject(_, let file):
            return "Selected file is outside the project folder: \(file.path)"
        case .editorNotInstalled(.zed):
            return "Zed is not installed. Install Zed to use Open in Editor."
        case .editorCLIUnavailable(let editor, let path):
            return "Could not locate \(editor.displayName) CLI at: \(path)"
        case .launchFailed(let editor, let reason):
            return "Failed to open in \(editor.displayName): \(reason)"
        }
    }
}

protocol ExternalEditorServiceProtocol {
    var defaultEditor: ExternalEditorID { get }
    var availableEditors: [ExternalEditorDescriptor] { get }

    func open(projectRootURL: URL, editor: ExternalEditorID?) throws
    func open(projectRootURL: URL, fileURL: URL, editor: ExternalEditorID?) throws
}

final class ExternalEditorService: ExternalEditorServiceProtocol {
    static let shared = ExternalEditorService()

    typealias ResolveApplicationURL = (_ bundleIdentifier: String) -> URL?
    typealias LaunchProcess = (_ executable: String, _ arguments: [String]) throws -> Void

    private let fileManager: FileManager
    private let resolveApplicationURL: ResolveApplicationURL
    private let launchProcess: LaunchProcess

    init(
        fileManager: FileManager = .default,
        resolveApplicationURL: @escaping ResolveApplicationURL = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        launchProcess: @escaping LaunchProcess = ExternalEditorService.defaultLaunchProcess
    ) {
        self.fileManager = fileManager
        self.resolveApplicationURL = resolveApplicationURL
        self.launchProcess = launchProcess
    }

    var defaultEditor: ExternalEditorID {
        .zed
    }

    var availableEditors: [ExternalEditorDescriptor] {
        [
            ExternalEditorDescriptor(id: .zed, displayName: "Zed")
        ]
    }

    func open(projectRootURL: URL, editor: ExternalEditorID? = nil) throws {
        try open(projectRootURL: projectRootURL, fileURL: nil, editor: editor)
    }

    func open(projectRootURL: URL, fileURL: URL, editor: ExternalEditorID? = nil) throws {
        try open(projectRootURL: projectRootURL, fileURL: Optional(fileURL), editor: editor)
    }

    private func open(projectRootURL: URL, fileURL: URL?, editor: ExternalEditorID? = nil) throws {
        let resolvedProjectRoot = projectRootURL.standardizedFileURL.resolvingSymlinksInPath()

        var isProjectRootDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolvedProjectRoot.path, isDirectory: &isProjectRootDirectory),
            isProjectRootDirectory.boolValue
        else {
            throw ExternalEditorError.projectRootNotFound(resolvedProjectRoot)
        }

        let resolvedFileURL: URL?
        if let fileURL {
            let candidateFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            var isTargetDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: candidateFileURL.path, isDirectory: &isTargetDirectory),
                !isTargetDirectory.boolValue
            else {
                throw ExternalEditorError.fileNotFound(candidateFileURL)
            }
            guard path(candidateFileURL.path, isInside: resolvedProjectRoot.path) else {
                throw ExternalEditorError.fileOutsideProject(
                    projectRoot: resolvedProjectRoot,
                    file: candidateFileURL
                )
            }
            resolvedFileURL = candidateFileURL
        } else {
            resolvedFileURL = nil
        }

        let targetEditor = editor ?? defaultEditor

        switch targetEditor {
        case .zed:
            try openInZed(projectRootURL: resolvedProjectRoot, fileURL: resolvedFileURL)
        }
    }

    private func openInZed(projectRootURL: URL, fileURL: URL?) throws {
        let bundleIdentifier = "dev.zed.Zed"

        guard let appURL = resolveApplicationURL(bundleIdentifier) else {
            throw ExternalEditorError.editorNotInstalled(.zed)
        }

        let cliURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: false)

        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw ExternalEditorError.editorCLIUnavailable(.zed, path: cliURL.path)
        }

        do {
            // Open workspace root first, then optional file path so Zed activates
            // the file within that project rather than opening file-only context.
            var arguments = [projectRootURL.path]
            if let fileURL {
                arguments.append(fileURL.path)
            }
            try launchProcess(cliURL.path, arguments)
        } catch {
            throw ExternalEditorError.launchFailed(.zed, reason: error.localizedDescription)
        }
    }

    private static func defaultLaunchProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}

private extension ExternalEditorID {
    var displayName: String {
        switch self {
        case .zed:
            return "Zed"
        }
    }
}
