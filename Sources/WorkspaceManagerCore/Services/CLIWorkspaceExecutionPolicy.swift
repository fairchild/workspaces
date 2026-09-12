// Keeps host-only CLI commands outside Compose-owned checkouts. Host-owned
// Compose receipts cover older CLI records that lost their backend identity,
// including when the app is offline or a path names a checkout subdirectory.

import Foundation

public enum CLIWorkspaceExecutionPolicy {
    public enum Failure: LocalizedError {
        case providerWorkspace(String)
        case unreadableOwnership

        public var errorDescription: String? {
            switch self {
            case .providerWorkspace(let provider):
                return "Host-only CLI commands cannot operate on a \(provider) workspace. "
                    + "Use its terminal in WorkSpaces or run an explicit container command."
            case .unreadableOwnership:
                return "Could not verify saved Docker Compose workspace ownership. "
                    + "Repair its host-owned workspace receipt before using host-only CLI commands."
            }
        }
    }

    public static func requireHostExecution(
        at directory: URL,
        backendIdentifier: String? = nil,
        composeWorkspacePaths: [String] = [],
        composeRuntimeRoot: URL = ComposeWorkspaceRuntime.defaultRuntimeRoot
    ) throws {
        if backendIdentifier == "compose" {
            throw Failure.providerWorkspace("Docker Compose")
        }
        let target = CLIPathNormalizer.normalized(directory.path)
        let paths = composeWorkspacePaths + (try composeCheckoutPaths(at: composeRuntimeRoot))
        if paths.contains(where: { path in
            let root = CLIPathNormalizer.normalized(path)
            return target == root || target.hasPrefix(root + "/")
        }) {
            throw Failure.providerWorkspace("Docker Compose")
        }
    }

    private struct Receipt: Decodable {
        let hostPath: String
    }

    private static func composeCheckoutPaths(at root: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        do {
            let projects = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            return try projects.filter { $0.lastPathComponent.hasPrefix("ws-") }.compactMap { project in
                let values = try project.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw Failure.unreadableOwnership
                }
                let receipt = project.appendingPathComponent("workspace.json")
                guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
                let attributes = try FileManager.default.attributesOfItem(atPath: receipt.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                    (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 1_048_576
                else { throw Failure.unreadableOwnership }
                return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt)).hostPath
            }
        } catch {
            throw Failure.unreadableOwnership
        }
    }
}
