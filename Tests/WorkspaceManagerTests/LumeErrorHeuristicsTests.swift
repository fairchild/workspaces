//
//  LumeErrorHeuristicsTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("LumeErrorHeuristics")
struct LumeErrorHeuristicsTests {
    // The orphan reconciler deletes a VM it just found on disk, addressed through the `workspaces`
    // storage selector — so a Lume not-found means that storage location isn't registered, and the
    // generic "Not found" should become the actionable storage diagnostic.

    @Test("A Lume not-found during cleanup maps to the workspaces-storage diagnostic")
    func notFoundMapsToStorageDiagnostic() {
        let error = LumeHTTPClientError.server("Not found")
        #expect(
            LumeErrorHeuristics.missingWorkspacesStorageDiagnostic(for: error)
                == LumeErrorHeuristics.workspacesStorageMissingMessage
        )
    }

    @Test("A raw HTTP 404 body maps to the workspaces-storage diagnostic")
    func http404MapsToStorageDiagnostic() {
        let error = LumeHTTPClientError.server("HTTP 404")
        #expect(
            LumeErrorHeuristics.missingWorkspacesStorageDiagnostic(for: error)
                == LumeErrorHeuristics.workspacesStorageMissingMessage
        )
    }

    @Test("The diagnostic points users at `lume storage list`")
    func diagnosticIsActionable() {
        #expect(LumeErrorHeuristics.workspacesStorageMissingMessage.contains("lume storage list"))
        #expect(LumeErrorHeuristics.workspacesStorageMissingMessage.contains("workspaces"))
    }

    @Test("Unrelated Lume failures are left untouched")
    func unrelatedErrorNotMapped() {
        let error = LumeHTTPClientError.server("connection refused")
        #expect(LumeErrorHeuristics.missingWorkspacesStorageDiagnostic(for: error) == nil)
    }
}
