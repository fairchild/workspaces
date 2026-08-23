//
//  UIFixtureFileTreeFailureBootstrap.swift
//  WorkspaceManager
//
//  Stages deterministic Detail Pane file-tree failures for visual evidence.
//  The configuration is debug-only so production binaries cannot simulate errors.
//

import Foundation
import WorkspaceManagerCore

/// Launch-surface request for deterministic file-tree recovery evidence. The type stays in every
/// build because ContentView names it; only debug builds carry the arming key and error injection.
struct UIFixtureFileTreeFailureBootstrapConfiguration: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case directoryUnavailable
        case permissionDenied
    }

    let failure: Failure

    #if DEBUG
        static let failureEnvKey = "WORKSPACES_UI_FIXTURE_FILE_TREE_FAILURE"

        static func from(environment: [String: String]) -> Self? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1",
                let rawValue = environment[failureEnvKey]
            else { return nil }

            let failure: Failure
            switch rawValue {
            case "unavailable":
                failure = .directoryUnavailable
            case "permission":
                failure = .permissionDenied
            default:
                return nil
            }
            return Self(failure: failure)
        }

        var simulatedError: any Error {
            switch failure {
            case .directoryUnavailable:
                return GitError.fileTreeRootUnavailable
            case .permissionDenied:
                return NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadNoPermissionError
                )
            }
        }
    #else
        static func from(environment: [String: String]) -> Self? { nil }
    #endif
}
