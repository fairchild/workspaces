//
//  UIFixtureSelectedWorkspaceBootstrapTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("UIFixtureSelectedWorkspaceBootstrap")
struct UIFixtureSelectedWorkspaceBootstrapTests {
    private let key = UIFixtureSelectedWorkspaceBootstrapConfiguration.workspaceNameKey

    /// The container is handed back with the repos: it owns the models, and letting it go out
    /// of scope resets the context out from under them mid-test.
    private struct Fixtures {
        let container: ModelContainer
        let repos: [Repo]
    }

    private func seededFixtures() throws -> Fixtures {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        UIFixtureSeeder.seedDataIfNeeded(in: context)
        return Fixtures(container: container, repos: try context.fetch(FetchDescriptor<Repo>()))
    }

    @Test("Parsing needs fixture mode and a name with something in it")
    func parsingNeedsFixtureModeAndAName() {
        #expect(UIFixtureSelectedWorkspaceBootstrapConfiguration.from(environment: [:]) == nil)
        #expect(
            UIFixtureSelectedWorkspaceBootstrapConfiguration.from(
                environment: [key: "feature-auth"]
            ) == nil
        )
        #expect(
            UIFixtureSelectedWorkspaceBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1"]
            ) == nil
        )
        #expect(
            UIFixtureSelectedWorkspaceBootstrapConfiguration.from(
                environment: ["WORKSPACES_UI_FIXTURE": "1", key: "   "]
            ) == nil
        )
    }

    @Test("A name survives the surrounding whitespace a shell leaves on it")
    func parsingTrimsTheName() {
        let configuration = UIFixtureSelectedWorkspaceBootstrapConfiguration.from(
            environment: ["WORKSPACES_UI_FIXTURE": "1", key: "  feature-auth\n"]
        )
        #expect(configuration?.workspaceName == "feature-auth")
    }

    @Test("The named workspace resolves against the seeded repos, case-insensitively")
    func resolvesTheNamedWorkspace() throws {
        let f = try seededFixtures()
        let configuration = UIFixtureSelectedWorkspaceBootstrapConfiguration(
            workspaceName: "Feature-Auth"
        )

        #expect(configuration.workspace(in: f.repos)?.name == "feature-auth")
    }

    @Test("A name nothing answers to resolves to nothing rather than to some other row")
    func unknownNameResolvesToNothing() throws {
        let f = try seededFixtures()
        let configuration = UIFixtureSelectedWorkspaceBootstrapConfiguration(
            workspaceName: "no-such-workspace"
        )

        #expect(configuration.workspace(in: f.repos) == nil)
    }

    /// Selecting an archived workspace lands on its repo overview, so naming one would stage a
    /// capture of something other than the card that was asked for. Skipping it makes the
    /// mismatch a logged no-op instead.
    @Test("An archived workspace is skipped rather than selected")
    func archivedWorkspaceIsSkipped() throws {
        let f = try seededFixtures()
        let featureAuth = try #require(
            f.repos.flatMap(\.workspaces).first { $0.name == "feature-auth" }
        )
        featureAuth.status = .archived

        let configuration = UIFixtureSelectedWorkspaceBootstrapConfiguration(
            workspaceName: "feature-auth"
        )
        #expect(configuration.workspace(in: f.repos) == nil)
    }

    @Test("Selection resolves with no repos in hand")
    func noReposResolvesToNothing() {
        let configuration = UIFixtureSelectedWorkspaceBootstrapConfiguration(
            workspaceName: "feature-auth"
        )
        #expect(configuration.workspace(in: []) == nil)
    }
}
