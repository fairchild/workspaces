//
//  CLIPathNormalizer.swift
//  WorkspaceManagerCore
//
//  One spelling for a filesystem path: tilde expanded, standardized, symlinks resolved.
//  Path is the only key the CLI-local store and the running app's inventory share, so
//  both sides pass through here before any cross-plane comparison.
//

import Foundation

public enum CLIPathNormalizer {
    public static func normalizedURL(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func normalized(_ path: String) -> String {
        normalizedURL(path).path
    }
}
