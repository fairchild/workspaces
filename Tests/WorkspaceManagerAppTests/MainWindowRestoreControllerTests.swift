//
//  MainWindowRestoreControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the main window's restore-banner flow: the order the three suppression
//  reasons are checked in, what acting on a plan persists, and what each restored surface
//  launches with. The plan's own predicates are covered in TerminalRestorePlannerTests.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowRestore")
struct MainWindowRestoreControllerTests {
    private let controller = MainWindowRestoreController()
    private let seedDirectory = URL(fileURLWithPath: "/Users/dev")

    // MARK: - Fixtures

    private func surface(
        action: RestoreSurfaceAction = .freshShell,
        key: HostTerminalSessionKey = .hostPath("/Users/dev/code/alpha"),
        directory: URL = URL(fileURLWithPath: "/Users/dev/code/alpha")
    ) -> RestoreSurfacePlan {
        RestoreSurfacePlan(
            hostSessionID: UUID(),
            key: key,
            directory: directory,
            action: action
        )
    }

    private func plan(
        _ surfaces: [RestoreSurfacePlan],
        previousRunID: String? = "run-1"
    ) -> RestorePlan {
        RestorePlan(
            surfaces: surfaces,
            selectedHostSessionID: surfaces.first?.hostSessionID,
            previousRunID: previousRunID
        )
    }

    private func disposition(
        for plan: RestorePlan,
        handledRunID: String = ""
    ) -> MainWindowRestoreController.PlanDisposition {
        controller.disposition(
            for: plan,
            handledRunID: handledRunID,
            seedKey: .defaultHome,
            seedDirectory: seedDirectory
        )
    }

    // MARK: - Which plans raise the banner

    @Test("A plan with real surfaces from an unhandled run is offered")
    func unhandledPlanIsOffered() {
        #expect(disposition(for: plan([surface(action: .resumeClaude(agentSessionID: "a"))])) == .offer)
    }

    @Test("An empty plan raises nothing")
    func emptyPlanIsNotOffered() {
        #expect(disposition(for: plan([])) == .noRestorableSurfaces)
    }

    @Test("A plan whose run was already acted on is suppressed")
    func handledPlanIsSuppressed() {
        let result = disposition(
            for: plan([surface(action: .resumeClaude(agentSessionID: "a"))], previousRunID: "run-1"),
            handledRunID: "run-1"
        )

        #expect(result == .alreadyHandled(previousRunID: "run-1"))
    }

    @Test("A different prior run is still offered")
    func differentRunIsStillOffered() {
        let result = disposition(
            for: plan([surface(action: .resumeClaude(agentSessionID: "a"))], previousRunID: "run-2"),
            handledRunID: "run-1"
        )

        #expect(result == .offer)
    }

    /// An empty stored id means "nothing handled yet", so it must be normalized to `nil` before
    /// the comparison. Passing it through verbatim would make it match a plan whose own run id
    /// is empty and silently suppress the banner — this is the case that pins the normalization,
    /// since a `nil` prior run is already rejected by `wasHandled` on its own.
    @Test("An empty stored handled-run id never matches an empty prior-run id")
    func emptyHandledRunIDIsNotARunName() {
        let result = disposition(
            for: plan([surface(action: .resumeClaude(agentSessionID: "a"))], previousRunID: ""),
            handledRunID: ""
        )

        #expect(result == .offer)
    }

    @Test("A plan with no run identity is offered rather than assumed handled")
    func planWithoutRunIdentityIsOffered() {
        let result = disposition(
            for: plan([surface(action: .resumeClaude(agentSessionID: "a"))], previousRunID: nil),
            handledRunID: "run-1"
        )

        #expect(result == .offer)
    }

    @Test("A plan that only reproduces the launch seed is suppressed")
    func launchSeedDuplicateIsSuppressed() {
        let seedOnly = plan([
            surface(action: .freshShell, key: .defaultHome, directory: seedDirectory)
        ])

        #expect(disposition(for: seedOnly) == .onlyDuplicatesLaunchSeed)
    }

    /// A fresh shell on the seed key at a *different* directory is a real restore — the default
    /// host directory can change between runs.
    @Test("A fresh shell on the seed key elsewhere is a real restore")
    func seedKeyAtAnotherDirectoryIsOffered() {
        let elsewhere = plan([
            surface(
                action: .freshShell,
                key: .defaultHome,
                directory: URL(fileURLWithPath: "/Users/dev/other")
            )
        ])

        #expect(disposition(for: elsewhere) == .offer)
    }

    // MARK: - Ordering between the reasons

    /// The rule this extraction locks in. Each predicate was individually testable before, but
    /// nothing pinned which one reports when several apply — and the answer is what the log says.
    @Test("An empty plan reports as empty even when its run was also handled")
    func emptinessOutranksHandled() {
        let result = disposition(for: plan([], previousRunID: "run-1"), handledRunID: "run-1")

        #expect(result == .noRestorableSurfaces)
    }

    @Test("A handled run is suppressed as handled even when it only duplicates the seed")
    func handledOutranksSeedDuplication() {
        let seedOnly = plan(
            [surface(action: .freshShell, key: .defaultHome, directory: seedDirectory)],
            previousRunID: "run-1"
        )

        #expect(disposition(for: seedOnly, handledRunID: "run-1") == .alreadyHandled(previousRunID: "run-1"))
    }

    // MARK: - Acting on a plan

    @Test("Acting on a plan persists its prior-run id")
    func handledRunIDIsThePriorRun() {
        #expect(controller.handledRunID(for: plan([surface()], previousRunID: "run-7")) == "run-7")
    }

    @Test("A plan with no run identity persists nothing")
    func planWithoutRunIDPersistsNothing() {
        #expect(controller.handledRunID(for: plan([surface()], previousRunID: nil)) == nil)
    }

    @Test("The banner hides once the user acts, and stays hidden")
    func dismissHidesTheBanner() {
        var state = MainWindowRestoreState()
        state.offer(plan([surface()]))
        #expect(state.bannerPlan != nil)

        state.dismissBanner()

        #expect(state.bannerPlan == nil)
    }

    @Test("An offered empty plan still shows no banner")
    func emptyOfferedPlanShowsNoBanner() {
        var state = MainWindowRestoreState()
        state.offer(plan([]))

        #expect(state.bannerPlan == nil)
    }

    @Test("With nothing offered there is no banner")
    func initialStateShowsNoBanner() {
        #expect(MainWindowRestoreState().bannerPlan == nil)
    }

    // MARK: - Autorun gate

    @Test("Autorun fires only for the explicit dev opt-in")
    func autorunRequiresTheExactFlag() {
        #expect(controller.isAutorunRequested(environment: ["WORKSPACES_RESTORE_AUTORUN": "1"]))
        #expect(controller.isAutorunRequested(environment: ["WORKSPACES_RESTORE_AUTORUN": "0"]) == false)
        #expect(controller.isAutorunRequested(environment: ["WORKSPACES_RESTORE_AUTORUN": "true"]) == false)
        #expect(controller.isAutorunRequested(environment: [:]) == false)
    }

    // MARK: - What each surface launches with

    @Test("Only resume surfaces carry an initial command")
    func initialCommandIsResumeOnly() {
        #expect(controller.initialCommand(for: .freshShell) == nil)
        #expect(controller.initialCommand(for: .reattachTmux(sessionName: "ws-alpha")) == nil)

        let resume = controller.initialCommand(for: .resumeClaude(agentSessionID: "abc123"))
        #expect(resume == RestoreLaunchCommand.claudeResume(sessionID: "abc123"))
        #expect(resume?.contains("abc123") == true)
    }

    @Test("Only resume surfaces have their tmux session killed first")
    func onlyResumeSurfacesAreKilled() {
        let resumeDirectory = URL(fileURLWithPath: "/Users/dev/code/beta")
        let target = plan([
            surface(action: .freshShell, directory: URL(fileURLWithPath: "/Users/dev/code/alpha")),
            surface(action: .resumeClaude(agentSessionID: "a"), directory: resumeDirectory),
            surface(
                action: .reattachTmux(sessionName: "ws-gamma"),
                directory: URL(fileURLWithPath: "/Users/dev/code/gamma")),
        ])

        #expect(controller.tmuxSessionDirectoriesToKill(in: target) == [resumeDirectory])
    }

    @Test("A plan with no resume surfaces kills nothing")
    func noResumeSurfacesKillNothing() {
        let target = plan([surface(action: .freshShell), surface(action: .reattachTmux(sessionName: "x"))])

        #expect(controller.tmuxSessionDirectoriesToKill(in: target).isEmpty)
    }

    @Test("Every key the plan restores is claimed, deduplicated")
    func ownedKeysCoverThePlanWithoutDuplicates() {
        let shared = HostTerminalSessionKey.hostPath("/Users/dev/code/alpha")
        let other = HostTerminalSessionKey.hostPath("/Users/dev/code/beta")
        let target = plan([
            surface(key: shared),
            surface(key: shared),
            surface(key: other),
        ])

        #expect(controller.ownedSessionKeys(in: target) == [shared, other])
    }
}
