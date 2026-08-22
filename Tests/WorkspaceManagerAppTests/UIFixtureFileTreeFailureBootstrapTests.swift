//
//  UIFixtureFileTreeFailureBootstrapTests.swift
//  WorkspaceManagerAppTests
//
//  Pins the deterministic evidence configuration for both rendered failure states.
//

import Testing

@testable import WorkspaceManager

@Suite("UIFixtureFileTreeFailureBootstrap")
struct UIFixtureFileTreeFailureBootstrapTests {
    @Test("Fixture mode recognizes only the two supported file-tree failures")
    func recognizesSupportedFailures() {
        let unavailable = UIFixtureFileTreeFailureBootstrapConfiguration.from(environment: [
            "WORKSPACES_UI_FIXTURE": "1",
            UIFixtureFileTreeFailureBootstrapConfiguration.failureEnvKey: "unavailable",
        ])
        let permission = UIFixtureFileTreeFailureBootstrapConfiguration.from(environment: [
            "WORKSPACES_UI_FIXTURE": "1",
            UIFixtureFileTreeFailureBootstrapConfiguration.failureEnvKey: "permission",
        ])
        let disabled = UIFixtureFileTreeFailureBootstrapConfiguration.from(environment: [
            UIFixtureFileTreeFailureBootstrapConfiguration.failureEnvKey: "unavailable"
        ])
        let unknown = UIFixtureFileTreeFailureBootstrapConfiguration.from(environment: [
            "WORKSPACES_UI_FIXTURE": "1",
            UIFixtureFileTreeFailureBootstrapConfiguration.failureEnvKey: "offline",
        ])

        #expect(unavailable?.failure == .directoryUnavailable)
        #expect(permission?.failure == .permissionDenied)
        #expect(disabled == nil)
        #expect(unknown == nil)
    }
}
