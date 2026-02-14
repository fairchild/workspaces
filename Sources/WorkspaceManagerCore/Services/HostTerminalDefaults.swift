//
//  HostTerminalDefaults.swift
//  WorkspaceManagerCore
//
//  Resolves the default launch directory for host-pinned terminals.
//

import Foundation

public enum HostTerminalDefaults {
    public static func defaultWorkingDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        resolveDefaultWorkingDirectory(
            tildeHomeDirectory: fileManager.homeDirectoryForCurrentUser,
            environmentHome: environment["HOME"],
            fileManager: fileManager
        )
    }

    public static func resolveDefaultWorkingDirectory(
        tildeHomeDirectory: URL,
        environmentHome: String?,
        fileManager: FileManager = .default
    ) -> URL {
        let normalizedTildeHome = tildeHomeDirectory.standardizedFileURL
        let tildeCodeDirectory = normalizedTildeHome.appendingPathComponent("code", isDirectory: true)

        if fileManager.directoryExists(at: tildeCodeDirectory) {
            return tildeCodeDirectory
        }

        guard let environmentHome, !environmentHome.isEmpty else {
            return normalizedTildeHome
        }

        let expandedEnvironmentHome = NSString(string: environmentHome).expandingTildeInPath
        let normalizedEnvironmentHome = URL(fileURLWithPath: expandedEnvironmentHome).standardizedFileURL
        let environmentCodeDirectory = normalizedEnvironmentHome.appendingPathComponent("code", isDirectory: true)

        if fileManager.directoryExists(at: environmentCodeDirectory) {
            return environmentCodeDirectory
        }

        return normalizedEnvironmentHome
    }
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
