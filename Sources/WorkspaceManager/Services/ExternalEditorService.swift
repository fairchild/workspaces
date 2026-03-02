import AppKit
import Foundation

enum ExternalEditorID: String, CaseIterable, Identifiable, Sendable {
    case zed
    case vscode
    case cursor
    case sublimeText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zed: return "Zed"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .sublimeText: return "Sublime Text"
        }
    }
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
        case .editorNotInstalled(let editor):
            return "\(editor.displayName) is not installed. Install \(editor.displayName) to use Open in Editor."
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

    private struct EditorSpec {
        let bundleIdentifier: String
        let cliRelativePath: String
        let appPathOverrideEnvKey: String?
    }

    private static let editorSpecs: [ExternalEditorID: EditorSpec] = [
        .zed: EditorSpec(
            bundleIdentifier: "dev.zed.Zed",
            cliRelativePath: "Contents/MacOS/cli",
            appPathOverrideEnvKey: "WORKSPACES_EDITOR_ZED_APP_PATH"
        ),
        .vscode: EditorSpec(
            bundleIdentifier: "com.microsoft.VSCode",
            cliRelativePath: "Contents/Resources/app/bin/code",
            appPathOverrideEnvKey: "WORKSPACES_EDITOR_VSCODE_APP_PATH"
        ),
        .cursor: EditorSpec(
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            cliRelativePath: "Contents/Resources/app/bin/cursor",
            appPathOverrideEnvKey: "WORKSPACES_EDITOR_CURSOR_APP_PATH"
        ),
        .sublimeText: EditorSpec(
            bundleIdentifier: "com.sublimetext.4",
            cliRelativePath: "Contents/SharedSupport/bin/subl",
            appPathOverrideEnvKey: "WORKSPACES_EDITOR_SUBLIME_APP_PATH"
        ),
    ]

    init(
        fileManager: FileManager = .default,
        resolveApplicationURL: @escaping ResolveApplicationURL = { bundleIdentifier in
            ExternalEditorService.defaultResolveApplicationURL(bundleIdentifier: bundleIdentifier)
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
        ExternalEditorID.allCases.map { ExternalEditorDescriptor(id: $0, displayName: $0.displayName) }
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
        try openInEditor(targetEditor, projectRootURL: resolvedProjectRoot, fileURL: resolvedFileURL)
    }

    private func openInEditor(_ editor: ExternalEditorID, projectRootURL: URL, fileURL: URL?) throws {
        guard let spec = Self.editorSpecs[editor] else {
            throw ExternalEditorError.editorNotInstalled(editor)
        }

        guard let appURL = resolveApplicationURL(spec.bundleIdentifier) else {
            throw ExternalEditorError.editorNotInstalled(editor)
        }

        let cliURL = appURL.appendingPathComponent(spec.cliRelativePath)

        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw ExternalEditorError.editorCLIUnavailable(editor, path: cliURL.path)
        }

        do {
            var arguments = [projectRootURL.path]
            if let fileURL {
                arguments.append(fileURL.path)
            }
            try launchProcess(cliURL.path, arguments)
        } catch {
            throw ExternalEditorError.launchFailed(editor, reason: error.localizedDescription)
        }
    }

    private static func defaultLaunchProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
    }

    private static func defaultResolveApplicationURL(bundleIdentifier: String) -> URL? {
        if let spec = editorSpecs.values.first(where: { $0.bundleIdentifier == bundleIdentifier }),
            let envKey = spec.appPathOverrideEnvKey,
            let overridePath = ProcessInfo.processInfo.environment[envKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !overridePath.isEmpty
        {
            let expandedPath = (overridePath as NSString).expandingTildeInPath
            let overrideURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: overrideURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return overrideURL
            }

            NSLog(
                "[ExternalEditor] Ignoring %@ override; directory missing at %@",
                envKey,
                overrideURL.path
            )
        }

        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}
