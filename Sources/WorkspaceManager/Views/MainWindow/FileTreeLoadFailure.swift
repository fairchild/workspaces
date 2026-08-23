//
//  FileTreeLoadFailure.swift
//  WorkspaceManager
//
//  Converts file-tree loader errors into calm, actionable Detail Pane states.
//  Keeps user-facing recovery copy and routing independent from SwiftUI rendering.
//

import Foundation
import WorkspaceManagerCore

struct FileTreeFinderLocation: Equatable, Sendable {
    let selectedPath: String?
    let viewerRootPath: String

    static func resolve(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) -> FileTreeFinderLocation {
        let targetURL = directoryURL.standardizedFileURL
        if fileManager.fileExists(atPath: targetURL.path) {
            return FileTreeFinderLocation(
                selectedPath: targetURL.path,
                viewerRootPath: targetURL.deletingLastPathComponent().path
            )
        }

        var candidateURL = targetURL.deletingLastPathComponent()
        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return FileTreeFinderLocation(
                    selectedPath: nil,
                    viewerRootPath: candidateURL.path
                )
            }

            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path {
                return FileTreeFinderLocation(
                    selectedPath: nil,
                    viewerRootPath: parentURL.path
                )
            }
            candidateURL = parentURL
        }
    }
}

enum FileTreeRecoveryAction: Equatable, Sendable {
    case revealInFinder
    case retry

    func perform(retry: () -> Void, revealInFinder: () -> Void) {
        switch self {
        case .revealInFinder:
            revealInFinder()
        case .retry:
            retry()
        }
    }
}

enum FileTreeLoadFailure: Error, Equatable, Sendable {
    case directoryUnavailable
    case permissionDenied
    case unreadable

    var reason: String {
        switch self {
        case .directoryUnavailable:
            return "This folder is no longer available on this Mac."
        case .permissionDenied:
            return "WorkSpaces does not have permission to read this folder."
        case .unreadable:
            return "The file tree could not be read."
        }
    }

    var recoveryAction: FileTreeRecoveryAction {
        switch self {
        case .directoryUnavailable, .permissionDenied:
            return .revealInFinder
        case .unreadable:
            return .retry
        }
    }

    var recoveryTitle: String {
        switch self {
        case .directoryUnavailable:
            return "Reveal Location"
        case .permissionDenied:
            return "Open in Finder"
        case .unreadable:
            return "Try Again"
        }
    }

    var recoverySystemImage: String {
        switch recoveryAction {
        case .revealInFinder:
            return "folder"
        case .retry:
            return "arrow.clockwise"
        }
    }

    static func classify(_ error: any Error) -> FileTreeLoadFailure {
        if let gitError = error as? GitError,
            gitError == .fileTreeRootUnavailable
        {
            return .directoryUnavailable
        }

        let nsError = error as NSError
        if matches(nsError, domain: NSCocoaErrorDomain, codes: [NSFileNoSuchFileError])
            || matches(nsError, domain: NSPOSIXErrorDomain, codes: [Int(ENOENT)])
        {
            return .directoryUnavailable
        }

        if matches(nsError, domain: NSCocoaErrorDomain, codes: [NSFileReadNoPermissionError])
            || matches(nsError, domain: NSPOSIXErrorDomain, codes: [Int(EACCES), Int(EPERM)])
        {
            return .permissionDenied
        }

        return .unreadable
    }

    private static func matches(_ error: NSError, domain: String, codes: Set<Int>) -> Bool {
        var candidate: NSError? = error
        while let current = candidate {
            if current.domain == domain, codes.contains(current.code) {
                return true
            }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
