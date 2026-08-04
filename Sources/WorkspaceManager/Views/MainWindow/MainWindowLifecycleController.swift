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
    /// Steps the window runs once, on first appearance.
    struct LaunchActions {
        let configureAutomationIntegration: () async -> Void
        let ensureInitialHostSession: () -> Void
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

    /// Launch order is load-bearing. Automation integration installs the verb layer before
    /// anything can drive it; the initial host session must exist before a restore plan is
    /// computed against it; and the fixtures need the surface lifecycle resolved before they
    /// select into it. The smoke lanes are told the window is ready last, once every earlier
    /// step has run, because that signal is what their harnesses wait on.
    func runLaunchSequence(_ actions: LaunchActions) async {
        await actions.configureAutomationIntegration()
        actions.ensureInitialHostSession()
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
        actions.refreshWorkspaceStatusAggregator()
        actions.refreshSessionSwitcherSnapshotIfPresented()
    }

    /// Teardown drops the window-scoped overrides so a lingering accessory app cannot keep
    /// routing shortcuts or driving gesture verbs through a window that is gone.
    func runTeardown(_ actions: TeardownActions) {
        actions.clearOpenInEditorShortcutOverride()
        actions.cancelStatusAggregation()
        actions.detachAutomationGestureVerbs()
    }
}
