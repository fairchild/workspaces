//
//  MainWindowLifecycleControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the order of the main window's launch, model-change, and teardown sequences.
//  The steps themselves live in the view; what is asserted here is that they run, run once, and
//  run in the order the surrounding machinery depends on.
//

import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowLifecycle")
struct MainWindowLifecycleControllerTests {
    private let controller = MainWindowLifecycleController()

    /// Records which steps ran, in order. A step name appearing twice is a duplicate run.
    private final class Recorder {
        private(set) var steps: [String] = []
        /// Which launch path invoked the terminal bootstrap, in order. The step name alone
        /// can't tell the prologue's call from the sequence's — and that distinction is what
        /// the caller label exists to carry into a perf sample (#1251).
        private(set) var bootstrapCallers: [MainWindowLifecycleController.BootstrapCaller] = []

        func record(_ name: String) {
            steps.append(name)
        }

        func step(_ name: String) -> () -> Void {
            { [weak self] in self?.record(name) }
        }

        func bootstrapStep(
            _ name: String
        ) -> (MainWindowLifecycleController.BootstrapCaller) -> Void {
            { [weak self] caller in
                self?.record(name)
                self?.bootstrapCallers.append(caller)
            }
        }

        /// Suspends before recording, so an ordering that only holds when nothing yields
        /// cannot pass: the sequence must actually await each step before running the next.
        func asyncStep(_ name: String) -> () async -> Void {
            { [weak self] in
                await Task.yield()
                self?.record(name)
            }
        }

        func index(of name: String) -> Int? {
            steps.firstIndex(of: name)
        }

        /// Whether `first` ran strictly before `second`, requiring both to have run.
        func ordered(_ first: String, before second: String) -> Bool {
            guard let a = index(of: first), let b = index(of: second) else { return false }
            return a < b
        }
    }

    private func launchActions(_ recorder: Recorder) -> MainWindowLifecycleController.LaunchActions {
        MainWindowLifecycleController.LaunchActions(
            configureAutomationIntegration: recorder.asyncStep("configureAutomationIntegration"),
            ensureInitialHostSession: recorder.bootstrapStep("ensureInitialHostSession"),
            computeRestorePlanIfEnabled: recorder.asyncStep("computeRestorePlanIfEnabled"),
            prewarmPerfTerminalSurfacesIfNeeded: recorder.step("prewarmPerfTerminalSurfaces"),
            resolveSurfaceLifecycle: recorder.step("resolveSurfaceLifecycle"),
            applyDiagnosticsFixtureIfNeeded: recorder.step("applyDiagnosticsFixture"),
            applySessionSwitcherFixtureIfNeeded: recorder.step("applySessionSwitcherFixture"),
            pruneRightPaneState: recorder.step("pruneRightPaneState"),
            syncOpenInEditorShortcutRouting: recorder.step("syncOpenInEditorShortcutRouting"),
            refreshWorkspaceStatusAggregator: recorder.step("refreshWorkspaceStatusAggregator"),
            noteHostLumeSmokeLaunchReady: recorder.asyncStep("noteHostLumeSmokeLaunchReady"),
            noteDesktopUISmokeLaunchReady: recorder.asyncStep("noteDesktopUISmokeLaunchReady")
        )
    }

    private func modelChangeActions(
        _ recorder: Recorder
    ) -> MainWindowLifecycleController.ModelChangeActions {
        MainWindowLifecycleController.ModelChangeActions(
            rebuildSelectionCaches: recorder.step("rebuildSelectionCaches"),
            releaseRemovedWebSources: recorder.step("releaseRemovedWebSources"),
            reconcileSelectionAfterModelChange: recorder.step("reconcileSelection"),
            resolveSurfaceLifecycle: recorder.step("resolveSurfaceLifecycle"),
            applyDiagnosticsFixtureIfNeeded: recorder.step("applyDiagnosticsFixture"),
            applySessionSwitcherFixtureIfNeeded: recorder.step("applySessionSwitcherFixture"),
            pruneRepoSessions: recorder.step("pruneRepoSessions"),
            refreshWorkspaceStatusAggregator: recorder.step("refreshWorkspaceStatusAggregator"),
            refreshSessionSwitcherSnapshotIfPresented: recorder.step("refreshSessionSwitcher")
        )
    }

    private func teardownActions(
        _ recorder: Recorder
    ) -> MainWindowLifecycleController.TeardownActions {
        MainWindowLifecycleController.TeardownActions(
            clearOpenInEditorShortcutOverride: recorder.step("clearShortcutOverride"),
            cancelStatusAggregation: recorder.step("cancelStatusAggregation"),
            detachAutomationGestureVerbs: recorder.step("detachGestureVerbs")
        )
    }

    // MARK: - Launch prologue

    /// The prologue exists to get the shell started before SwiftUI's first layout pass, so the
    /// terminal bootstrap has to be the step it runs (#1251).
    @Test("Prologue seeds the initial host session")
    func prologueSeedsInitialHostSession() {
        let recorder = Recorder()

        controller.runLaunchPrologue(launchActions(recorder), automationGatesTerminalBootstrap: false)

        #expect(recorder.steps == ["ensureInitialHostSession"])
    }

    /// A terminal's process environment carries the automation socket path and handle, which the
    /// listener only produces once it has bound. Starting a shell ahead of that would leave it
    /// unreachable to the API for its whole life, so the bootstrap stays in the sequence there.
    @Test("Prologue defers the bootstrap while the Automation API gates it")
    func prologueDefersBootstrapWhenAutomationGatesIt() {
        let recorder = Recorder()

        controller.runLaunchPrologue(launchActions(recorder), automationGatesTerminalBootstrap: true)

        #expect(recorder.steps.isEmpty)
    }

    /// The sequence still owns every step, including the one the prologue may have already run —
    /// `ensureInitialHostSession` is idempotent, and the steps after it read the session set.
    @Test("Prologue does not remove the bootstrap from the launch sequence")
    func prologueLeavesLaunchSequenceComplete() async {
        let recorder = Recorder()

        controller.runLaunchPrologue(launchActions(recorder), automationGatesTerminalBootstrap: false)
        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.steps.filter { $0 == "ensureInitialHostSession" }.count == 2)
        #expect(recorder.ordered("ensureInitialHostSession", before: "computeRestorePlanIfEnabled"))
    }

    /// Both calls are the same idempotent step, so only the label distinguishes the launch that
    /// seeded its session before the first layout pass from the one that seeded it after.
    @Test("Bootstrap reports which launch path called it")
    func bootstrapReportsCallingPath() async {
        let recorder = Recorder()

        controller.runLaunchPrologue(launchActions(recorder), automationGatesTerminalBootstrap: false)
        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.bootstrapCallers == [.prologue, .sequence])
    }

    /// A gated launch and a launch whose prologue simply lost the race produce the same timing;
    /// the caller label is what tells them apart in a sample.
    @Test("Gated prologue leaves the sequence as the only bootstrap caller")
    func gatedPrologueReportsSequenceAsOnlyCaller() async {
        let recorder = Recorder()

        controller.runLaunchPrologue(launchActions(recorder), automationGatesTerminalBootstrap: true)
        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.bootstrapCallers == [.sequence])
    }

    // MARK: - Launch

    /// The whole contract is the order, so this asserts the complete sequence rather than a
    /// set — a permutation of the middle steps would otherwise pass every other test here.
    @Test("Launch runs every step once, in order")
    func launchRunsEveryStepInOrder() async {
        let recorder = Recorder()

        await controller.runLaunchSequence(launchActions(recorder))

        #expect(
            recorder.steps == [
                "configureAutomationIntegration",
                "ensureInitialHostSession",
                "computeRestorePlanIfEnabled",
                "prewarmPerfTerminalSurfaces",
                "resolveSurfaceLifecycle",
                "applyDiagnosticsFixture",
                "applySessionSwitcherFixture",
                "pruneRightPaneState",
                "syncOpenInEditorShortcutRouting",
                "refreshWorkspaceStatusAggregator",
                "noteHostLumeSmokeLaunchReady",
                "noteDesktopUISmokeLaunchReady",
            ]
        )
    }

    /// Automation integration installs the verb layer, so it has to be up before anything can
    /// drive it — including the smoke lanes that wait on the ready signal.
    @Test("Launch configures automation before anything can drive it")
    func launchConfiguresAutomationFirst() async {
        let recorder = Recorder()

        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.steps.first == "configureAutomationIntegration")
    }

    /// A restore plan is computed against the session set, so the initial host session has to
    /// exist first or the plan is made against an emptier window than the user will see.
    @Test("Launch ensures the initial host session before planning a restore")
    func launchEnsuresSessionBeforeRestorePlan() async {
        let recorder = Recorder()

        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.ordered("ensureInitialHostSession", before: "computeRestorePlanIfEnabled"))
    }

    /// The fixtures select into the resolved surface, so surface resolution has to precede them.
    @Test("Launch resolves the surface before applying fixtures")
    func launchResolvesSurfaceBeforeFixtures() async {
        let recorder = Recorder()

        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.ordered("resolveSurfaceLifecycle", before: "applyDiagnosticsFixture"))
        #expect(recorder.ordered("resolveSurfaceLifecycle", before: "applySessionSwitcherFixture"))
    }

    /// The smoke harnesses block on these signals, so anything they expect to observe has to
    /// have already run.
    @Test("Launch signals the smoke lanes last")
    func launchSignalsSmokeLanesLast() async {
        let recorder = Recorder()

        await controller.runLaunchSequence(launchActions(recorder))

        #expect(recorder.steps.suffix(2) == ["noteHostLumeSmokeLaunchReady", "noteDesktopUISmokeLaunchReady"])
    }

    // MARK: - Model change

    @Test("Model change runs every step once, in order")
    func modelChangeRunsEveryStepInOrder() {
        let recorder = Recorder()

        controller.runModelChangeSequence(modelChangeActions(recorder))

        #expect(
            recorder.steps == [
                "rebuildSelectionCaches",
                "releaseRemovedWebSources",
                "reconcileSelection",
                "resolveSurfaceLifecycle",
                "applyDiagnosticsFixture",
                "applySessionSwitcherFixture",
                "pruneRepoSessions",
                // The aggregator refresh rebuilds an open switcher itself;
                // the explicit step doubled the snapshot projection (#1347).
                "refreshWorkspaceStatusAggregator",
            ]
        )
    }

    /// The rule this slice exists to lock in. Every later step resolves ids against the selection
    /// caches, so rebuilding them first is what stops the rest of the pass reading a stale index
    /// after a repo or workspace is deleted.
    @Test("Model change rebuilds selection caches before anything reads them")
    func modelChangeRebuildsCachesFirst() {
        let recorder = Recorder()

        controller.runModelChangeSequence(modelChangeActions(recorder))

        #expect(recorder.steps.first == "rebuildSelectionCaches")
    }

    /// Surface resolution reads the current selection, so a selection invalidated by the model
    /// change has to be reconciled before the surface resolves against it.
    @Test("Model change reconciles selection before resolving the surface")
    func modelChangeReconcilesBeforeResolvingSurface() {
        let recorder = Recorder()

        controller.runModelChangeSequence(modelChangeActions(recorder))

        #expect(recorder.ordered("reconcileSelection", before: "resolveSurfaceLifecycle"))
    }

    /// Sessions for repos that no longer exist are pruned before the aggregator rolls status up,
    /// so a removed repo cannot contribute a status to the sidebar on its way out.
    @Test("Model change prunes dead repo sessions before rolling status up")
    func modelChangePrunesBeforeAggregating() {
        let recorder = Recorder()

        controller.runModelChangeSequence(modelChangeActions(recorder))

        #expect(recorder.ordered("pruneRepoSessions", before: "refreshWorkspaceStatusAggregator"))
    }

    // MARK: - Teardown

    @Test("Teardown drops every window-scoped override exactly once")
    func teardownDropsEveryOverride() {
        let recorder = Recorder()

        controller.runTeardown(teardownActions(recorder))

        #expect(
            recorder.steps == [
                "clearShortcutOverride", "cancelStatusAggregation", "detachGestureVerbs",
            ]
        )
    }
}
