//
//  LumeErrorHeuristics.swift
//  WorkspaceManagerCore
//
//  Shared message classification for Lume runtime and provider fallbacks.
//

import Foundation

enum LumeErrorHeuristics {
    static func shouldFallbackToStockImage(_ error: Error) -> Bool {
        contains(
            error,
            fragments: [
                "fetch image manifest from registry",
                "fetch authentication token from registry",
                "denied",
                "not found",
            ]
        )
    }

    static func shouldTreatAsMissingVM(_ error: Error) -> Bool {
        contains(
            error,
            fragments: [
                "not found",
                "no vm",
                "does not exist",
            ]
        )
    }

    static func shouldRetryMacOSProvisioningWithCLI(_ error: Error) -> Bool {
        contains(
            error,
            fragments: [
                "restore image catalog failed to load",
                "installation service returned an unexpected error",
                "virtual machine not found",
            ]
        )
    }

    private static func contains(_ error: Error, fragments: [String]) -> Bool {
        let normalized = error.localizedDescription.lowercased()
        return fragments.contains(where: normalized.contains)
    }
}
