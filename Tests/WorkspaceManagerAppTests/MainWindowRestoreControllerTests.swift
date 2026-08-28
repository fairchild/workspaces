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

    @Test("The banner shows the plan it was offered, and hides once the user acts")
    func dismissHidesTheBanner() {
        var state = MainWindowRestoreState()
        let offered = plan([surface()])
        state.offer(offered)
        #expect(state.bannerPlan == offered)

        state.dismissBanner()

        #expect(state.bannerPlan == nil)
    }

    /// Dismissal is for the rest of the launch. A later plan computation must not resurrect the
    /// banner, which it would if `offer` reset the dismissal alongside the plan.
    @Test("A plan offered after dismissal stays hidden")
    func offerAfterDismissalStaysHidden() {
        var state = MainWindowRestoreState()
        state.offer(plan([surface()]))
        state.dismissBanner()

        state.offer(plan([surface()], previousRunID: "run-2"))

        #expect(state.bannerPlan == nil)
    }

    /// Acting on a plan with no run identity persists nothing, but must still hide the banner —
    /// the two halves are independent, and pairing them would leave such a plan on screen.
    @Test("Dismissal does not depend on the plan having a run identity")
    func dismissalIsIndependentOfRunIdentity() {
        var state = MainWindowRestoreState()
        let anonymous = plan([surface()], previousRunID: nil)
        state.offer(anonymous)

        #expect(controller.handledRunID(for: anonymous) == nil)

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

    /// Order and multiplicity both matter: the kill list is consumed in sequence, and two resume
    /// surfaces on the same directory are two kills. A `Set`-based rewrite would collapse them.
    @Test("The kill list keeps surface order and does not deduplicate")
    func killListPreservesOrderAndDuplicates() {
        let first = URL(fileURLWithPath: "/Users/dev/code/alpha")
        let second = URL(fileURLWithPath: "/Users/dev/code/beta")
        let target = plan([
            surface(action: .resumeClaude(agentSessionID: "a"), directory: first),
            surface(action: .freshShell, directory: URL(fileURLWithPath: "/Users/dev/code/skip")),
            surface(action: .resumeClaude(agentSessionID: "b"), directory: first),
            surface(action: .resumeClaude(agentSessionID: "c"), directory: second),
        ])

        let names = controller.tmuxSessionNamesToKill(
            in: target,
            ownedTmuxSessionNames: ["wm-alpha", "wm-beta"]
        ) { "wm-\($0.lastPathComponent)" }.kill

        #expect(names == ["wm-alpha", "wm-alpha", "wm-beta"])
    }

    @Test("Only resume surfaces have their tmux session killed first")
    func onlyResumeSurfacesAreKilled() {
        let target = plan([
            surface(action: .freshShell, directory: URL(fileURLWithPath: "/Users/dev/code/alpha")),
            surface(
                action: .resumeClaude(agentSessionID: "a"),
                directory: URL(fileURLWithPath: "/Users/dev/code/beta")),
            surface(
                action: .reattachTmux(sessionName: "ws-gamma"),
                directory: URL(fileURLWithPath: "/Users/dev/code/gamma")),
        ])

        let names = controller.tmuxSessionNamesToKill(
            in: target,
            ownedTmuxSessionNames: ["wm-alpha", "wm-beta", "wm-gamma"]
        ) { "wm-\($0.lastPathComponent)" }.kill

        #expect(names == ["wm-beta"])
    }

    @Test("A plan with no resume surfaces kills nothing")
    func noResumeSurfacesKillNothing() {
        let target = plan([surface(action: .freshShell), surface(action: .reattachTmux(sessionName: "x"))])

        // Both halves, and a permissive owned set: with an empty set a mutation that treated
        // fresh/reattach surfaces as candidates would hide them in `skippedUnowned` and still
        // pass on `kill` alone.
        let scope = controller.tmuxSessionNamesToKill(
            in: target,
            ownedTmuxSessionNames: ["wm-x", "wm-alpha", "x"]
        ) { "wm-\($0.lastPathComponent)" }

        #expect(scope.kill.isEmpty)
        #expect(scope.skippedUnowned.isEmpty)
    }

    /// The #1233 acceptance criterion: a resume and a reattach surface can share a directory,
    /// and the resume kill must not take down the session the reattach surface targets.
    @Test("The kill list never contains a reattach target's session name")
    func killListExcludesReattachTargets() {
        let shared = URL(fileURLWithPath: "/Users/dev/code/alpha")
        let target = plan([
            surface(action: .reattachTmux(sessionName: "wm-alpha"), directory: shared),
            surface(action: .resumeClaude(agentSessionID: "a"), directory: shared),
            surface(
                action: .resumeClaude(agentSessionID: "b"),
                directory: URL(fileURLWithPath: "/Users/dev/code/beta")),
        ])

        let names = controller.tmuxSessionNamesToKill(
            in: target,
            ownedTmuxSessionNames: ["wm-alpha", "wm-beta"]
        ) { "wm-\($0.lastPathComponent)" }.kill

        #expect(names == ["wm-beta"])
        #expect(!names.contains("wm-alpha"))
    }

    /// `-L workspaces` is a same-user shared socket and the candidate name is a directory
    /// derivation, so the same name can belong to a session a person or another tool started.
    /// This launch may only kill what it is holding (#1267).
    @Test("A session this launch does not own survives the pre-restore kill pass")
    func unownedSessionIsNotKilled() {
        let target = plan([
            surface(
                action: .resumeClaude(agentSessionID: "a"),
                directory: URL(fileURLWithPath: "/Users/dev/code/alpha"))
        ])

        let scope = controller.tmuxSessionNamesToKill(
            in: target,
            ownedTmuxSessionNames: []
        ) { "wm-\($0.lastPathComponent)" }

        #expect(scope.kill.isEmpty)
        #expect(scope.skippedUnowned == ["wm-alpha"])
    }

    /// The other half of the acceptance: scoping to owned names must not stop the pass from
    /// reclaiming this launch's own seed, which is the reason the kill exists at all.
    @Test("This launch's own seed is still reclaimed alongside a foreign session")
    func ownedSeedIsStillKilledWhileForeignSurvives() {
        let target = plan([
            surface(
                action: .resumeClaude(agentSessionID: "a"),
                directory: URL(fileURLWithPath: "/Users/dev/code/alpha")),
            surface(
                action: .resumeClaude(agentSessionID: "b"),
                directory: URL(fileURLWithPath: "/Users/dev/code/beta")),
        ])

        let scope = controller.tmuxSessionNamesToKill(
            in: target,
            ownedTmuxSessionNames: ["wm-beta"]
        ) { "wm-\($0.lastPathComponent)" }

        #expect(scope.kill == ["wm-beta"])
        #expect(scope.skippedUnowned == ["wm-alpha"])
    }

    /// Reattach surfaces launch on the name that was probed alive, so a directory fallback
    /// (workspace moved or archived) cannot silently start a fresh shell while the surviving
    /// session — possibly with a live agent — stays orphaned.
    @Test("Only reattach surfaces carry a tmux session name override")
    func tmuxOverrideIsReattachOnly() {
        #expect(controller.tmuxSessionNameOverride(for: .freshShell) == nil)
        #expect(controller.tmuxSessionNameOverride(for: .resumeClaude(agentSessionID: "a")) == nil)
        #expect(controller.tmuxSessionNameOverride(for: .reattachTmux(sessionName: "wm-alpha")) == "wm-alpha")
    }

    /// The #1233 shared-directory hazard, launch side: a resume surface's `-A` launch name
    /// can be the very session another surface reattaches to (it is excluded from the kill
    /// list). When the pre-launch probe reports that name still live, the resume command is
    /// suppressed — attaching is fine, typing `claude --resume` into the shared shell is not.
    @Test("A resume whose launch name is still live suppresses its initial command")
    func liveResumeTargetSuppressesInitialCommand() {
        let resume = surface(
            action: .resumeClaude(agentSessionID: "a"),
            directory: URL(fileURLWithPath: "/Users/dev/code/alpha"))
        let derive = { (url: URL) in "wm-\(url.lastPathComponent)" }

        #expect(controller.initialCommand(for: resume, liveSessionNames: ["wm-alpha"], sessionName: derive) == nil)
        #expect(
            controller.initialCommand(for: resume, liveSessionNames: [], sessionName: derive)
                == RestoreLaunchCommand.claudeResume(sessionID: "a"))
    }

    @Test("Only resume surfaces contribute probe-before-launch names")
    func probeNamesAreResumeOnly() {
        let target = plan([
            surface(action: .reattachTmux(sessionName: "wm-alpha")),
            surface(action: .freshShell, directory: URL(fileURLWithPath: "/Users/dev/code/beta")),
            surface(
                action: .resumeClaude(agentSessionID: "a"),
                directory: URL(fileURLWithPath: "/Users/dev/code/gamma")),
        ])

        #expect(controller.resumeLaunchSessionNames(in: target) { "wm-\($0.lastPathComponent)" } == ["wm-gamma"])
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

    // MARK: - Host-session identity

    /// The #1397 acceptance at the decision layer: rejoining a surviving tmux session
    /// keeps the identity its processes already export, while a surface that starts a
    /// new shell does not claim the old id.
    @Test("Only a reattach surface adopts its recorded host session id")
    func onlyReattachAdoptsRecordedHostSessionID() {
        let reattach = surface(action: .reattachTmux(sessionName: "wm-alpha"))
        let resume = surface(action: .resumeClaude(agentSessionID: "a"))
        let fresh = surface(action: .freshShell)

        #expect(controller.adoptedHostSessionID(for: reattach) == reattach.hostSessionID)
        #expect(controller.adoptedHostSessionID(for: resume) == nil)
        #expect(controller.adoptedHostSessionID(for: fresh) == nil)
    }
}
