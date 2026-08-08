//
//  SyntheticRunRootTests.swift
//  WorkspaceManagerTests
//
//  Coverage for the WORKSPACES_SYNTHETIC_ROOT resolution boundary.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("SyntheticRunRoot")
struct SyntheticRunRootTests {
    @Test("Resolves a non-empty value to a directory URL")
    func resolvesNonEmptyValue() {
        let url = SyntheticRunRoot.url(
            environment: [SyntheticRunRoot.environmentKey: "/tmp/synthetic-root"]
        )
        #expect(url?.path == "/tmp/synthetic-root")
    }

    @Test("Unset, empty, and whitespace-only values resolve to nil")
    func rejectsEmptyValues() {
        #expect(SyntheticRunRoot.url(environment: [:]) == nil)
        #expect(SyntheticRunRoot.url(environment: [SyntheticRunRoot.environmentKey: ""]) == nil)
        #expect(SyntheticRunRoot.url(environment: [SyntheticRunRoot.environmentKey: "  \n"]) == nil)
    }
}
