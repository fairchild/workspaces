// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
//
//  MainWindowLateModelDeliveryTests.swift
//  WorkspaceManagerAppTests
//
//  The saved last surface must survive a resolution pass that runs before the
//  `@Query` arrays arrive (#845), and a genuinely stale one must still be
//  cleared once they have. Today's local SQLite store fetches synchronously
//  before `onAppear`, so the late delivery is constructed here rather than
//  waited for: the first pass is handed empty arrays, the second the populated
//  ones, which is the ordering a large store or an async container would make
//  real.
//
import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowLateModelDelivery")
struct MainWindowLateModelDeliveryTests {
    private let controller = MainWindowSurfaceResolutionController()
    private let bootstrapController = MainWindowBootstrapController()

    @Test("A valid repo surface survives a resolution pass that precedes delivery")
    func validRepoSurfaceSurvivesLateDelivery() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let saved = MainWindowLastSurface(kind: .repoOverview, id: repo.id)

        // Pass one: the store has not delivered. Nothing is known about the
        // saved id, so nothing may be destroyed on its account.
        switch action(rawValue: saved.rawValue, repos: [], webSources: []) {
        case .none:
            break
        default:
            Issue.record("Expected no action while the query arrays are undelivered")
        }

        // Pass two: delivery lands and the saved selection restores.
        switch action(rawValue: saved.rawValue, repos: [repo], webSources: []) {
        case .restore(.repoOverview(let restored)):
            #expect(restored.id == repo.id)
        default:
            Issue.record("Expected the saved surface to restore once the repos arrive")
        }
    }

    @Test("A valid workspace surface survives a resolution pass that precedes delivery")
    func validWorkspaceSurfaceSurvivesLateDelivery() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]
        let saved = MainWindowLastSurface(kind: .workspaceTerminal, id: workspace.id)

        switch action(rawValue: saved.rawValue, repos: [], webSources: []) {
        case .none:
            break
        default:
            Issue.record("Expected no action while the query arrays are undelivered")
        }

        switch action(rawValue: saved.rawValue, repos: [repo], webSources: []) {
        case .restore(.workspace(let restored)):
            #expect(restored.id == workspace.id)
        default:
            Issue.record("Expected the saved workspace to restore once the repos arrive")
        }
    }

    @Test("A saved web source survives a launch that resolves before it arrives")
    @MainActor
    func savedWebSourceSurvivesCrossCollectionOrdering() {
        // The ordering a decision-only test cannot catch: repos arrive first, so
        // a fallback is available and gets applied. Applying a fallback normally
        // records it as the last surface, which would destroy the saved web
        // source just as surely as clearing it. This drives the real action
        // handler across both passes, carrying the mutated state and the
        // persisted value from one into the next.
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]
        let source = WebSource(
            name: "docs", baseURLString: "https://example.com", allowedHost: "example.com")
        let savedRawValue = MainWindowLastSurface(kind: .webView, id: source.id).rawValue
        var persisted = savedRawValue
        var state = MainWindowViewState()
        var appliedSurfaces: [String] = []
        var provisionalSurfaces: [String] = []

        let handler = MainWindowLaunchActionHandler()
        let actions = MainWindowLaunchActionHandler.Actions(
            clearDeepLink: {},
            clearLastSurface: { persisted = "" },
            discardPendingRemoteConnection: { _ in },
            importRepo: { _ in nil },
            selectWorkspace: { _, _ in },
            selectRepoTerminal: { _, _ in },
            selectWebSource: { _ in },
            applyLaunchSurface: { surface in
                appliedSurfaces.append(Self.describe(surface))
                // Production selection records the surface it applies.
                persisted = Self.persistedRawValue(for: surface)
            },
            applyProvisionalLaunchSurface: { surface in
                provisionalSurfaces.append(Self.describe(surface))
            },
            schedulePerfAutoSelect: { _, _ in },
            focusWorkspaceWindow: {}
        )

        // Pass one: repos delivered, web sources not.
        handler.apply(
            action(rawValue: persisted, repos: [repo], webSources: []),
            state: &state,
            environment: [:],
            pendingRequest: nil,
            bootstrapController: bootstrapController,
            actions: actions
        )

        #expect(provisionalSurfaces == ["workspace:feature-a"])
        #expect(appliedSurfaces.isEmpty)
        #expect(persisted == savedRawValue, "the saved surface must survive the provisional pass")
        #expect(!state.didResolveInitialSurface, "the launch has not resolved while a surface waits")

        // Pass two: the web sources land and the saved surface restores.
        handler.apply(
            action(rawValue: persisted, repos: [repo], webSources: [source]),
            state: &state,
            environment: [:],
            pendingRequest: nil,
            bootstrapController: bootstrapController,
            actions: actions
        )

        #expect(appliedSurfaces == ["webView:docs"])
        #expect(state.didResolveInitialSurface)
    }

    @Test("A saved repo surface survives web sources arriving first")
    func savedRepoSurfaceSurvivesWebSourcesArrivingFirst() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let source = WebSource(
            name: "docs", baseURLString: "https://example.com", allowedHost: "example.com")
        let saved = MainWindowLastSurface(kind: .repoOverview, id: repo.id).rawValue

        switch action(rawValue: saved, repos: [], webSources: [source]) {
        case .provisionalFallback(.webView(let provisional)):
            #expect(provisional.id == source.id)
        case .clearInvalidLastSurface, .fallback:
            Issue.record("A repo surface must not be overwritten against an undelivered repo list")
        default:
            Issue.record("Expected a provisional fallback while the repos are undelivered")
        }

        switch action(rawValue: saved, repos: [repo], webSources: [source]) {
        case .restore(.repoOverview(let restored)):
            #expect(restored.id == repo.id)
        default:
            Issue.record("Expected the saved repo surface to restore once the repos arrive")
        }
    }

    @Test("The undelivered pass leaves the persisted raw value intact")
    func undeliveredPassLeavesRawValueIntact() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let saved = MainWindowLastSurface(kind: .repoOverview, id: repo.id)

        // The model-change repair path sanitises the same raw value through the
        // same decision, so it has to hold the line too. `rawValue` re-encodes on
        // every read and JSON key order is not stable across encodings, so the
        // value under test is captured once.
        let rawValue = saved.rawValue
        let sanitised = bootstrapController.sanitizedLastSurfaceRawValue(
            rawValue: rawValue,
            repos: [],
            webSources: []
        )

        #expect(sanitised == rawValue)
    }

    @Test("A genuinely stale surface is still cleared once the models are delivered")
    func staleSurfaceStillClears() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let stale = MainWindowLastSurface(kind: .repoTerminal, id: UUID())

        switch action(rawValue: stale.rawValue, repos: [repo], webSources: []) {
        case .clearInvalidLastSurface:
            break
        default:
            Issue.record("A stale surface must still be cleared against a delivered repo list")
        }

        #expect(
            bootstrapController.sanitizedLastSurfaceRawValue(
                rawValue: stale.rawValue,
                repos: [repo],
                webSources: []
            ) == ""
        )
    }

    @Test("A stale web surface is still cleared once web sources are delivered")
    func staleWebSurfaceStillClears() {
        let source = WebSource(name: "docs", baseURLString: "https://example.com", allowedHost: "example.com")
        let stale = MainWindowLastSurface(kind: .webView, id: UUID())

        #expect(
            bootstrapController.sanitizedLastSurfaceRawValue(
                rawValue: stale.rawValue,
                repos: [],
                webSources: [source]
            ) == ""
        )
    }

    @Test("An archived workspace is still cleared, delivery having happened")
    func archivedWorkspaceStillClears() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        workspace.status = .archived
        repo.workspaces = [workspace]
        let saved = MainWindowLastSurface(kind: .workspaceTerminal, id: workspace.id)

        #expect(
            bootstrapController.sanitizedLastSurfaceRawValue(
                rawValue: saved.rawValue,
                repos: [repo],
                webSources: []
            ) == ""
        )
    }

    private static func describe(_ surface: MainWindowLaunchSurface) -> String {
        switch surface {
        case .repoOverview(let repo): return "repoOverview:\(repo.name)"
        case .repoTerminal(let repo): return "repoTerminal:\(repo.name)"
        case .workspace(let workspace): return "workspace:\(workspace.name)"
        case .webView(let source): return "webView:\(source.name)"
        }
    }

    private static func persistedRawValue(for surface: MainWindowLaunchSurface) -> String {
        switch surface {
        case .repoOverview(let repo):
            return MainWindowLastSurface(kind: .repoOverview, id: repo.id).rawValue
        case .repoTerminal(let repo):
            return MainWindowLastSurface(kind: .repoTerminal, id: repo.id).rawValue
        case .workspace(let workspace):
            return MainWindowLastSurface(kind: .workspaceTerminal, id: workspace.id).rawValue
        case .webView(let source):
            return MainWindowLastSurface(kind: .webView, id: source.id).rawValue
        }
    }

    private func action(
        rawValue: String,
        repos: [Repo],
        webSources: [WebSource]
    ) -> MainWindowSurfaceResolutionAction {
        controller.nextAction(
            context: MainWindowSurfaceResolutionContext(
                environment: [:],
                didRunPerfAutoSelection: false,
                didApplyFixturePreviewBootstrap: false,
                didApplyFixtureWebBootstrap: false,
                didResolveInitialSurface: false,
                pendingRequest: nil,
                lastSurfaceRawValue: rawValue,
                previewConfiguration: nil,
                webConfiguration: nil,
                repos: repos,
                webSources: webSources
            ),
            bootstrapController: bootstrapController
        )
    }
}
