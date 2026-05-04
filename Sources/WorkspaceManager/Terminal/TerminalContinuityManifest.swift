//
//  TerminalContinuityManifest.swift
//  WorkspaceManager
//

import Foundation

struct TerminalContinuityManifest: Codable, Equatable {
    enum TargetKind: String, Codable {
        case repo
        case workspace
    }

    static let storageKey = "terminalContinuity.manifest.v1"

    let version: Int
    let targetKind: TargetKind
    let targetID: UUID
    let rootPath: String
    let launchPath: String
    let terminalMode: TerminalMultiplexingMode
    let tmuxSessionName: String
    let updatedAt: Date

    init(
        targetKind: TargetKind,
        targetID: UUID,
        rootURL: URL,
        launchURL: URL,
        terminalMode: TerminalMultiplexingMode,
        updatedAt: Date = Date()
    ) {
        let normalizedRoot = Self.normalizedPath(for: rootURL)
        let normalizedLaunch = Self.normalizedPath(for: launchURL)

        self.version = 1
        self.targetKind = targetKind
        self.targetID = targetID
        self.rootPath = normalizedRoot
        self.launchPath = normalizedLaunch
        self.terminalMode = terminalMode
        self.tmuxSessionName = GhosttyTerminalConfig.tmuxSessionName(
            for: URL(fileURLWithPath: normalizedLaunch, isDirectory: true)
        )
        self.updatedAt = updatedAt
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(from rawValue: String) -> TerminalContinuityManifest? {
        guard !rawValue.isEmpty else { return nil }
        guard let data = rawValue.data(using: .utf8) else { return nil }
        guard let manifest = try? JSONDecoder().decode(TerminalContinuityManifest.self, from: data) else {
            return nil
        }
        guard manifest.version == 1 else { return nil }
        return manifest
    }

    func launchDirectory(
        for targetKind: TargetKind,
        targetID: UUID,
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let normalizedRoot = Self.normalizedPath(for: rootURL)
        guard self.targetKind == targetKind,
            self.targetID == targetID,
            rootPath == normalizedRoot
        else {
            return nil
        }

        if Self.isExistingDirectory(launchPath, fileManager: fileManager),
            Self.path(launchPath, isInside: normalizedRoot)
        {
            return URL(fileURLWithPath: launchPath, isDirectory: true)
        }

        guard Self.isExistingDirectory(normalizedRoot, fileManager: fileManager) else {
            return nil
        }
        return URL(fileURLWithPath: normalizedRoot, isDirectory: true)
    }

    private static func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private static func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}
