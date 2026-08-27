//
//  MainWindowLifecycleController.swift
//  WorkspaceManager
//
//  The main window's three multi-step lifecycle sequences — launch, model change, and teardown —
//  as ordered code rather than inline modifier bodies. Each step is supplied by the view; what
//  lives here is the order they run in, which is load-bearing and was previously expressed only
//  by the sequence of statements inside an `.onAppear` closure.
//

import Foundation

@MainActor
struct MainWindowLifecycleController {
    /// Which launch path invoked the terminal bootstrap. Both paths call it and it is
    /// idempotent, so the caller that actually seeded the session decides whether the first
    /// render pass has a terminal to realize — the split `launch_to_first_prompt` reads as
    /// bimodal (#1251). The bootstrap reports its caller so a perf sample carries the mode it
    /// ran in rather than leaving it to be inferred from the timing distribution.
    enum BootstrapCaller: String, Sendable {
        case prologue
        case sequence
    }

    /// Steps the window runs once, on first appearance.
    struct LaunchActions {
        let configureAutomationIntegration: () async -> Void
        let ensureInitialHostSession: (BootstrapCaller) -> Void
        let computeRestorePlanIfEnabled: () async -> Void
        let prewarmPerfTerminalSurfacesIfNeeded: () -> Void
        let resolveSurfaceLifecycle: () -> Void
        let applyDiagnosticsFixtureIfNeeded: () -> Void
        let applySessionSwitcherFixtureIfNeeded: () -> Void
        let pruneRightPaneState: () -> Void
        let syncOpenInEditorShortcutRouting: () -> Void
        let refreshWorkspaceStatusAggregator: () -> Void
        let noteHostLumeSmokeLaunchReady: () async -> Void
        let noteDesktopUISmokeLaunchReady: () async -> Void
        let reattachPreviouslyOpenSurfaces: () async -> Void
    }

    /// Steps the window runs whenever the set of repos, workspaces, or web sources changes.
    struct ModelChangeActions {
        let rebuildSelectionCaches: () -> Void
        let releaseRemovedWebSources: () -> Void
        let reconcileSelectionAfterModelChange: () -> Void
        let resolveSurfaceLifecycle: () -> Void
        let applyDiagnosticsFixtureIfNeeded: () -> Void
        let applySessionSwitcherFixtureIfNeeded: () -> Void
        let pruneRepoSessions: () -> Void
        let refreshWorkspaceStatusAggregator: () -> Void
        let refreshSessionSwitcherSnapshotIfPresented: () -> Void
    }

    /// Steps the window runs when it goes away.
    struct TeardownActions {
        let clearOpenInEditorShortcutOverride: () -> Void
        let cancelStatusAggregation: () -> Void
        let detachAutomationGestureVerbs: () -> Void
    }

    /// The part of launch that runs synchronously inside `onAppear`, ahead of the launch task.
    ///
    /// Only the terminal bootstrap lives here, and only because it is on the `launch_to_first_prompt`
    /// critical path: the interval opens at `applicationDidFinishLaunching` and closes when the first
    /// shell signals a prompt, so the shell cannot start until this session exists. A task body queued
    /// from `onAppear` does not begin until SwiftUI's first layout pass releases the main actor —
    /// measured at 270–360 ms on a cold debug launch (#1251) — and the shell start waits out all of it.
    /// Seeding the session here instead lets the first render pass realize the terminal.
    ///
    /// `ensureInitialHostSession` is idempotent (it no-ops once the store has sessions), so
    /// `runLaunchSequence` still calls it and its ordering guarantees hold whether or not this ran.
    ///
    /// `automationGatesTerminalBootstrap` is the one case that keeps the bootstrap in the sequence:
    /// with the Automation API on, a terminal's process environment carries the automation socket
    /// path and handle, and those exist only after the listener binds. A shell started before that
    /// would be unreachable to the API for its whole life, so on that path the bootstrap waits.
    func runLaunchPrologue(_ actions: LaunchActions, automationGatesTerminalBootstrap: Bool) {
        guard !automationGatesTerminalBootstrap else { return }
        actions.ensureInitialHostSession(.prologue)
    }

    /// Launch order is load-bearing. Automation integration installs the verb layer before
    /// anything can drive it; the initial host session must exist before a restore plan is
    /// computed against it; and the fixtures need the surface lifecycle resolved before they
    /// select into it. The smoke lanes are told the window is ready last among the steps that
    /// build the window, because that signal is what their harnesses wait on.
    ///
    /// Rejoining the previous run's other scopes runs after that signal, alone at the end: it
    /// starts a shell per scope, and every step above — including `launch_to_first_prompt`,
    /// which closes on the first shell's prompt — is finished by the time it does.
    func runLaunchSequence(_ actions: LaunchActions) async {
        await actions.configureAutomationIntegration()
        actions.ensureInitialHostSession(.sequence)
        await actions.computeRestorePlanIfEnabled()
        actions.prewarmPerfTerminalSurfacesIfNeeded()
        actions.resolveSurfaceLifecycle()
        actions.applyDiagnosticsFixtureIfNeeded()
        actions.applySessionSwitcherFixtureIfNeeded()
        actions.pruneRightPaneState()
        actions.syncOpenInEditorShortcutRouting()
        actions.refreshWorkspaceStatusAggregator()
        await actions.noteHostLumeSmokeLaunchReady()
        await actions.noteDesktopUISmokeLaunchReady()
        await actions.reattachPreviouslyOpenSurfaces()
    }

    /// Model-change order is load-bearing too: the selection caches are rebuilt first so every
    /// later step resolves ids against current models rather than a stale index, and selection is
    /// reconciled before the surface lifecycle so the surface resolves against a valid selection.
    func runModelChangeSequence(_ actions: ModelChangeActions) {
        actions.rebuildSelectionCaches()
        actions.releaseRemovedWebSources()
        actions.reconcileSelectionAfterModelChange()
        actions.resolveSurfaceLifecycle()
        actions.applyDiagnosticsFixtureIfNeeded()
        actions.applySessionSwitcherFixtureIfNeeded()
        actions.pruneRepoSessions()
        // The aggregator refresh rebuilds an open switcher itself once the
        // update lands; a second explicit rebuild here doubled the snapshot
        // projection.
        actions.refreshWorkspaceStatusAggregator()
    }

    /// Teardown drops the window-scoped overrides so a lingering accessory app cannot keep
    /// routing shortcuts or driving gesture verbs through a window that is gone.
    func runTeardown(_ actions: TeardownActions) {
        actions.clearOpenInEditorShortcutOverride()
        actions.cancelStatusAggregation()
        actions.detachAutomationGestureVerbs()
    }
}
