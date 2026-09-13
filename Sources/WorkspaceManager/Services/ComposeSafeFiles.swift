// Reads host-visible Compose files without following agent-created symbolic
// links. Directory-relative file descriptors preserve the boundary even when
// the agent replaces a path between enumeration and preview.

import Darwin
import Foundation
import WorkspaceManagerCore

enum ComposeSafeFiles {
    enum Failure: LocalizedError {
        case invalidPath
        case unavailable
        case notRegularFile
        case tooManyFiles

        var errorDescription: String? {
            switch self {
            case .invalidPath:
                return "The selected file must be inside this workspace."
            case .unavailable:
                return
                    "This path is unavailable or contains a symbolic link. Sandbox previews do not follow symbolic links."
            case .notRegularFile:
                return "Only regular files can be previewed from a sandbox."
            case .tooManyFiles:
                return "This workspace contains too many files to display. Use its terminal to browse."
            }
        }
    }

    static func validate(relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.contains("\0"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Failure.invalidPath }
    }

    static func fileTree(at root: URL) throws -> FileNode {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var budget = 5_000
        return try tree(descriptor: descriptor, name: root.lastPathComponent, path: "", depth: 0, budget: &budget)
    }

    static func preview(root: URL, relativePath: String) async throws -> CodePreviewPayload {
        try await Task.detached(priority: .userInitiated) {
            let data = try read(root: root, relativePath: relativePath, limit: CodePreviewLoader.maxPreviewBytes + 1)
            guard !data.contains(0) else { throw CodePreviewError.binaryFile }
            let truncated = data.count > CodePreviewLoader.maxPreviewBytes
            let prefix = data.prefix(CodePreviewLoader.maxPreviewBytes)
            let text: String
            if truncated {
                text = String(decoding: prefix, as: UTF8.self)
            } else if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
            } else {
                throw CodePreviewError.unsupportedEncoding
            }
            let language = CodeSyntaxLanguage(fileExtension: (relativePath as NSString).pathExtension)
            return CodePreviewPayload(
                text: text,
                language: language,
                spans: CodeSyntaxHighlighter.highlightSpans(
                    in: text, language: language, maxCharacters: CodePreviewLoader.maxHighlightCharacters
                ),
                isTruncated: truncated,
                readOnlyReason: "Sandbox files are read-only here. Edit them in the workspace terminal."
            )
        }.value
    }

    static func read(root: URL, relativePath: String, limit: Int) throws -> Data {
        try validate(relativePath: relativePath)
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let flags =
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let child = openat(descriptor, component, flags)
            guard child >= 0 else { throw Failure.unavailable }
            close(descriptor)
            descriptor = child
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw Failure.notRegularFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.read(upToCount: max(0, limit)) ?? Data()
    }

    private static func tree(
        descriptor: Int32, name: String, path: String, depth: Int, budget: inout Int
    ) throws -> FileNode {
        guard depth < 4 else { return FileNode(name: name, path: path, isDirectory: true, children: nil) }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw Failure.unavailable }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw Failure.unavailable
        }
        defer { closedir(directory) }
        let ignored: Set<String> = ["node_modules", "build", "DerivedData", "__pycache__", "venv"]
        var children: [FileNode] = []
        while let entry = readdir(directory) {
            let itemName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard !itemName.hasPrefix("."), !ignored.contains(itemName) else { continue }
            budget -= 1
            guard budget >= 0 else { throw Failure.tooManyFiles }
            var metadata = stat()
            guard fstatat(descriptor, itemName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            let childPath = path.isEmpty ? itemName : "\(path)/\(itemName)"
            if kind == mode_t(S_IFDIR) {
                let child = openat(descriptor, itemName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { continue }
                defer { close(child) }
                children.append(
                    try tree(descriptor: child, name: itemName, path: childPath, depth: depth + 1, budget: &budget))
            } else if kind == mode_t(S_IFREG) {
                children.append(FileNode(name: itemName, path: childPath, isDirectory: false, children: nil))
            }
        }
        children.sort {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return FileNode(name: name, path: path, isDirectory: true, children: children)
    }
}
