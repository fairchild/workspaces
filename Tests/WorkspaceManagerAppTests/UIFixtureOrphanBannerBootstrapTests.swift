//
//  UIFixtureOrphanBannerBootstrapTests.swift
//  WorkspaceManagerAppTests
//
//  Pins what each orphan-banner fixture seed stages: one item, a long expanded list, or
//  nothing, so evidence captures and their ui-state goldens stay deterministic.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("UIFixtureOrphanBannerBootstrap")
struct UIFixtureOrphanBannerBootstrapTests {
    private let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)

    private func environment(seed: String?) -> [String: String] {
        var environment = ["WORKSPACES_UI_FIXTURE": "1"]
        environment[UIFixtureOrphanBannerBootstrap.seedEnvKey] = seed
        return environment
    }

    @Test("Each seed value stages its own scan result")
    func seedValuesStageTheirScanResult() throws {
        let single = try #require(
            UIFixtureOrphanBannerBootstrap.fixtureScanResult(
                environment: environment(seed: "1"), homeDirectory: home))
        let overflow = try #require(
            UIFixtureOrphanBannerBootstrap.fixtureScanResult(
                environment: environment(seed: "overflow"), homeDirectory: home))
        let unseeded = UIFixtureOrphanBannerBootstrap.fixtureScanResult(
            environment: environment(seed: nil), homeDirectory: home)
        let outsideFixture = UIFixtureOrphanBannerBootstrap.fixtureScanResult(
            environment: [UIFixtureOrphanBannerBootstrap.seedEnvKey: "overflow"], homeDirectory: home)

        #expect(single.map(\.id) == ["fixture:git-worktree:stale-experiment"])
        #expect(overflow.count == UIFixtureOrphanBannerBootstrap.overflowItemCount)
        #expect(Set(overflow.map(\.id)).count == overflow.count)
        #expect(unseeded?.isEmpty == true)
        #expect(outsideFixture == nil)
    }

    @Test("Only the overflow seed opens the list")
    func onlyOverflowStartsExpanded() {
        #expect(UIFixtureOrphanBannerBootstrap.startsExpanded(environment: environment(seed: "overflow")))
        #expect(!UIFixtureOrphanBannerBootstrap.startsExpanded(environment: environment(seed: "1")))
        #expect(
            !UIFixtureOrphanBannerBootstrap.startsExpanded(
                environment: [UIFixtureOrphanBannerBootstrap.seedEnvKey: "overflow"]))
    }
}
