//
//  GhosttyResourcesLocator.swift
//  WorkspaceManager
//

import Foundation

enum GhosttyResourcesLocator {
    static let environmentVariableName = "GHOSTTY_RESOURCES_DIR"

    static func bundledResourcesDirectory(
        resourcesURL: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourcesURL else { return nil }

        let ghosttyDirectory = resourcesURL.appendingPathComponent("ghostty", isDirectory: true)
        guard isUsableResourcesDirectory(ghosttyDirectory, fileManager: fileManager) else {
            return nil
        }

        return ghosttyDirectory
    }

    static func resolvedResourcesDirectory(
        existingEnvironmentValue: String?,
        resourcesURL: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let existingDirectory = normalizedDirectoryURL(path: existingEnvironmentValue),
            isUsableResourcesDirectory(existingDirectory, fileManager: fileManager)
        {
            return existingDirectory
        }

        return bundledResourcesDirectory(resourcesURL: resourcesURL, fileManager: fileManager)
    }

    @discardableResult
    static func configureProcessEnvironment(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let existingValue = environment[environmentVariableName]
        guard
            let directory = resolvedResourcesDirectory(
                existingEnvironmentValue: existingValue,
                resourcesURL: bundle.resourceURL,
                fileManager: fileManager
            )
        else {
            return nil
        }

        if normalizedDirectoryURL(path: existingValue)?.path != directory.path {
            setenv(environmentVariableName, directory.path, 1)
        }

        return directory
    }

    private static func normalizedDirectoryURL(path: String?) -> URL? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private static func isUsableResourcesDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        let terminfoParent = directory.deletingLastPathComponent()
        let terminfoSentinel = terminfoParent.appendingPathComponent(
            "terminfo/78/xterm-ghostty",
            isDirectory: false
        )
        return fileManager.fileExists(atPath: terminfoSentinel.path)
    }
}
