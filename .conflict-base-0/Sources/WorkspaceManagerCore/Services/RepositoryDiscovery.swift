//
//  RepositoryDiscovery.swift
//  WorkspaceManagerCore
//
//  Discovers git repositories under a host directory.
//

import Foundation

public enum RepositoryDiscovery {
    public static func discoverGitRepositories(
        in rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return []
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return
            contents
            .filter { candidate in
                guard directoryExists(at: candidate, fileManager: fileManager) else {
                    return false
                }
                return gitMarkerExists(in: candidate, fileManager: fileManager)
            }
            .map(\.standardizedFileURL)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    private static func gitMarkerExists(in directory: URL, fileManager: FileManager) -> Bool {
        let gitMarker = directory.appendingPathComponent(".git")
        return fileManager.fileExists(atPath: gitMarker.path)
    }

    private static func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
