//
//  LumeErrorHeuristics.swift
//  WorkspaceManagerCore
//
//  Shared message classification for Lume runtime and provider fallbacks.
//

import Foundation

public enum LumeErrorHeuristics {
    /// User-facing diagnostic for a Lume "not found" failure during workspace-VM cleanup. The
    /// orphan reconciler only offers a VM for cleanup after finding its directory in the workspace
    /// VM storage, and cleanup always addresses it through the `workspaces` storage selector — so a
    /// not-found from Lume means that storage location is not registered in Lume, not that the VM
    /// is gone. A generic "Not found" hid that distinction. Returns nil for other errors so the
    /// original error stands.
    public static func missingWorkspacesStorageDiagnostic(for error: Error) -> String? {
        guard contains(error, fragments: ["not found", "404"]) else {
            return nil
        }
        return workspacesStorageMissingMessage
    }

    public static let workspacesStorageMissingMessage =
        "The 'workspaces' storage location is not configured in Lume. "
        + "Run `lume storage list` to verify it exists, then add it before retrying cleanup."

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
