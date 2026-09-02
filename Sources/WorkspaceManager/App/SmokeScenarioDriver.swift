//
//  SmokeScenarioDriver.swift
//  WorkspaceManager
//
//  The single seam between production views and the debug-only smoke/fixture
//  harness. Debug builds forward every hook to the host-Lume and desktop-UI
//  smoke controllers and drive their scenarios; release builds compile an inert
//  shell so none of the harness ships.
//

import Foundation
import SwiftUI
import WorkspaceManagerCore

/// View capabilities the smoke scenarios drive, supplied by `SidebarView` per
/// call so the driver enters the same selection/creation paths a user gesture
/// does. Constructed in every configuration; only debug builds ever invoke it.
@MainActor
struct SmokeScenarioSidebarContext {
    let repos: [Repo]
    let webSources: [WebSource]
    let selectedWorkspace: @MainActor () -> Workspace?
    let sidebarWorkspaces: @MainActor () -> [Workspace]
    let normalizePath: @MainActor (URL) -> String
    let presentError: @MainActor (String) -> Void
    let addRepo: @MainActor (URL) async -> Void
    let createWorkspace:
        @MainActor (_ repo: Repo, _ name: String, _ providerID: String, _ guestOS: WorkspaceGuestOS?) async -> Void
    let selectRepoTerminal: @MainActor (Repo) -> Void
    let selectWorkspace: @MainActor (Workspace) -> Void
    let selectWebSource: @MainActor (WebSource) -> Void
    let insertWebSource: @MainActor (WebSource) -> Bool
}

#if DEBUG
    @MainActor
    final class SmokeScenarioDriver: ObservableObject {
        let hostLume: HostLumeSmokeAutomationController
        let desktopUI: DesktopUISmokeAutomationController

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            hostLume = HostLumeSmokeAutomationController(environment: environment)
            desktopUI = DesktopUISmokeAutomationController(environment: environment)
        }

        /// Whether the deterministic Lume UI fixture is armed. Always false in release.
        nonisolated static var isLumeFixtureEnabled: Bool {
            UIFixtureLumeEnvironment.isEnabled()
        }

        // MARK: - Scenario driving (SidebarView)

        func driveScenariosIfNeeded(_ context: SmokeScenarioSidebarContext) async {
            await driveHostLumeScenarioIfNeeded(context)
            await driveDesktopUIScenarioIfNeeded(context)
        }

        func driveHostLumeScenarioIfNeeded(_ context: SmokeScenarioSidebarContext) async {
            guard hostLume.isEnabled else { return }
            guard let targetRepoURL = hostLume.targetRepoURL else { return }

            if let matchedRepo = hostLume.matchingRepo(in: context.repos, normalizePath: context.normalizePath) {
                await hostLume.noteRepoReady(matchedRepo)

                guard hostLume.shouldStartWorkspaceCreation() else { return }
                await hostLume.noteWorkspaceCreationStarted(repo: matchedRepo)
                await context.createWorkspace(
                    matchedRepo,
                    hostLume.targetWorkspaceName ?? "lume-smoke",
                    LumeWorkspaceProvider.identifier,
                    .macOS
                )
                return
            }

            guard FileManager.default.fileExists(atPath: targetRepoURL.path) else {
                context.presentError("Smoke repo path does not exist: \(targetRepoURL.path)")
                return
            }

            await context.addRepo(targetRepoURL)
        }

        /// Drives the daily-driver desktop flows for the `desktop-ui-smoke`
        /// automation mode: import the target repo if needed, create a local
        /// workspace, confirm it lands in the sidebar with a live terminal, then
        /// switch selection to the repo terminal and back to prove the surface
        /// follows selection. Milestones stream to the events JSONL the host smoke
        /// script asserts against.
        func driveDesktopUIScenarioIfNeeded(_ context: SmokeScenarioSidebarContext) async {
            guard desktopUI.isEnabled else { return }
            guard let targetRepoURL = desktopUI.targetRepoURL else { return }

            guard
                let repo = desktopUI.matchingRepo(
                    in: context.repos,
                    normalizePath: context.normalizePath
                )
            else {
                guard FileManager.default.fileExists(atPath: targetRepoURL.path) else {
                    context.presentError("Desktop UI smoke repo path does not exist: \(targetRepoURL.path)")
                    return
                }
                await context.addRepo(targetRepoURL)
                return
            }

            await desktopUI.noteRepoReady(repo)
            guard desktopUI.shouldStartScenario() else { return }
            if desktopUI.usesAPICreateDriver {
                let attachBaselineBeforeRepoPark = desktopUI.terminalAttachCount
                let focusBaselineBeforeRepoPark = desktopUI.surfaceFocusCount
                // Only the full parity configuration hands the repo park outside (#958).
                // api-create-smoke.sh enables the create driver alone and answers no
                // repo-terminal handoff, so externalizing on that flag by itself would
                // strand that lane for the whole wait and then fail its repo-attach
                // assertion. Same both-drivers condition noteAPIWorkspaceCreateCompleted uses.
                let repoParkIsExternal = desktopUI.usesAPISelectDriver
                if repoParkIsExternal {
                    await desktopUI.noteAwaitingAPIRepoTerminal(repo: repo)
                } else {
                    context.selectRepoTerminal(repo)
                }
                // A round trip needs a wider budget than an in-process gesture.
                let parkTimeout: Duration = repoParkIsExternal ? .seconds(60) : .seconds(15)
                _ = await desktopUI.waitForTerminalAttach(
                    after: attachBaselineBeforeRepoPark,
                    timeout: parkTimeout
                )
                _ = await desktopUI.waitForSurfaceFocus(
                    after: focusBaselineBeforeRepoPark,
                    timeout: parkTimeout
                )
                await desktopUI.noteAwaitingAPICreate(repo: repo)
                return
            }
            await runDesktopUIScenario(repo: repo, context: context)
        }

        private func runDesktopUIScenario(repo: Repo, context: SmokeScenarioSidebarContext) async {
            let workspaceName = desktopUI.targetWorkspaceName ?? "desktop-ui-smoke"

            await desktopUI.noteWorkspaceCreationStarted(repo: repo)

            let attachBaselineBeforeCreate = desktopUI.terminalAttachCount
            let focusBaselineBeforeCreate = desktopUI.surfaceFocusCount
            await context.createWorkspace(
                repo,
                workspaceName,
                LocalWorkspaceProvider.identifier,
                nil
            )

            guard let workspace = context.selectedWorkspace() else {
                await desktopUI.noteFailure(
                    message: "Local workspace was not created or selected."
                )
                return
            }

            await noteWorkspaceCreated(workspace, sidebarWorkspaces: context.sidebarWorkspaces)

            // Flow 1: the freshly created workspace's terminal attaches (hard gate),
            // then focus (best-effort; skipped when activation is suppressed).
            _ = await desktopUI.waitForTerminalAttach(
                after: attachBaselineBeforeCreate,
                timeout: .seconds(15)
            )
            _ = await desktopUI.waitForSurfaceFocus(
                after: focusBaselineBeforeCreate,
                timeout: .seconds(15)
            )

            // API-driven select variant: park the active surface on the repo terminal, then hand the
            // reselect to an external `workspace.select` verb. The verb enters the same selection binding
            // this scenario's `selectWorkspace` writes, so it must produce the identical
            // `terminal_session_attached` milestone — and switch the active PTY off the repo terminal,
            // which is the wrong-PTY guard proven end to end.
            if desktopUI.usesAPISelectDriver {
                let attachBaselineBeforeRepoPark = desktopUI.terminalAttachCount
                let focusBaselineBeforeRepoPark = desktopUI.surfaceFocusCount
                context.selectRepoTerminal(repo)
                _ = await desktopUI.waitForTerminalAttach(
                    after: attachBaselineBeforeRepoPark,
                    timeout: .seconds(15)
                )
                _ = await desktopUI.waitForSurfaceFocus(
                    after: focusBaselineBeforeRepoPark,
                    timeout: .seconds(15)
                )
                await desktopUI.noteAwaitingAPISelect(workspace: workspace)
                return
            }

            // Flow 2: switch selection to the repo terminal, then back to the
            // workspace. Distinct attached session IDs prove the surface follows
            // selection rather than stranding a stale session.
            let attachBaselineBeforeRepo = desktopUI.terminalAttachCount
            let focusBaselineBeforeRepo = desktopUI.surfaceFocusCount
            context.selectRepoTerminal(repo)
            _ = await desktopUI.waitForTerminalAttach(
                after: attachBaselineBeforeRepo,
                timeout: .seconds(15)
            )
            _ = await desktopUI.waitForSurfaceFocus(
                after: focusBaselineBeforeRepo,
                timeout: .seconds(15)
            )

            let attachBaselineBeforeReselect = desktopUI.terminalAttachCount
            let focusBaselineBeforeReselect = desktopUI.surfaceFocusCount
            context.selectWorkspace(workspace)
            _ = await desktopUI.waitForTerminalAttach(
                after: attachBaselineBeforeReselect,
                timeout: .seconds(15)
            )
            _ = await desktopUI.waitForSurfaceFocus(
                after: focusBaselineBeforeReselect,
                timeout: .seconds(15)
            )

            // Flow 3: web main content renders through the Surface seam, then returning to the
            // workspace routes a terminal session again (session routing is the hard gate; surface
            // focus stays best-effort in headless runs, like Flows 1–2). about:blank keeps the gate
            // network-independent — the milestone is the surface mount, not a page load.
            if let webSource = ensureDesktopUIWebSource(context: context) {
                let webBaseline = desktopUI.webSurfaceAttachCount
                context.selectWebSource(webSource)
                let webAttached = await desktopUI.waitForWebSurfaceAttach(
                    after: webBaseline,
                    timeout: .seconds(10)
                )
                if !webAttached {
                    await desktopUI.noteFailure(
                        message: "Web surface did not mount after web source selection."
                    )
                }

                let attachBaselineAfterWeb = desktopUI.terminalAttachCount
                let focusBaselineAfterWeb = desktopUI.surfaceFocusCount
                context.selectWorkspace(workspace)
                _ = await desktopUI.waitForTerminalAttach(
                    after: attachBaselineAfterWeb,
                    timeout: .seconds(15)
                )
                _ = await desktopUI.waitForSurfaceFocus(
                    after: focusBaselineAfterWeb,
                    timeout: .seconds(15)
                )
            }

            await desktopUI.noteScenarioComplete()
        }

        /// The web source Flow 3 selects, created on first run. `about:blank` renders without network.
        private func ensureDesktopUIWebSource(context: SmokeScenarioSidebarContext) -> WebSource? {
            let name = "desktop-ui-smoke-web"
            if let existing = context.webSources.first(where: { $0.name == name }) {
                return existing
            }
            let source = WebSource(name: name, baseURLString: "about:blank", allowedHost: "")
            guard context.insertWebSource(source) else { return nil }
            return source
        }

        /// Confirms the new workspace is present under its repo in the live sidebar
        /// model before emitting `sidebar_updated`, polling briefly because the
        /// `@Query` repo list can lag a save by a run loop.
        private func emitSidebarUpdate(
            for workspace: Workspace,
            sidebarWorkspaces: @MainActor () -> [Workspace]
        ) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                let workspaces = sidebarWorkspaces()
                if workspaces.contains(where: { $0.id == workspace.id }) {
                    await desktopUI.noteSidebarUpdated(
                        workspace: workspace,
                        sidebarWorkspaceCount: workspaces.count
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            await desktopUI.noteFailure(
                message: "Created workspace did not appear in the sidebar: \(workspace.name)"
            )
        }

        // MARK: - Failure and creation lifecycle notes (SidebarView)

        func noteFailure(message: String) async {
            await hostLume.noteFailure(
                message: message,
                recoveryHints: lumeRecoveryHints(for: message)
            )
            await desktopUI.noteFailure(message: message)
        }

        func noteWorkspaceCreationPhase(message: String) async {
            await hostLume.noteWorkspacePhaseChanged(message: message)
        }

        func noteWorkspacePersisted(_ result: WorkspaceProviderCreationResult) async {
            await hostLume.noteWorkspacePersisted(HostLumeSmokeWorkspaceRecord(result: result))
        }

        func noteWorkspaceActive(_ workspace: Workspace) async {
            await hostLume.noteWorkspaceActive(HostLumeSmokeWorkspaceRecord(workspace: workspace))
        }

        func noteWorkspaceCreated(
            _ workspace: Workspace,
            sidebarWorkspaces: @MainActor () -> [Workspace]
        ) async {
            await desktopUI.noteWorkspaceCreated(workspace)
            await emitSidebarUpdate(for: workspace, sidebarWorkspaces: sidebarWorkspaces)
        }

        // MARK: - Launch and provider-setup lifecycle notes (ContentView)

        func noteHostLumeLaunchReady() async {
            await hostLume.noteLaunchReady()
        }

        func noteDesktopUILaunchReady() async {
            await desktopUI.noteLaunchReady()
        }

        func noteHostWorkspaceFailure(message: String) async {
            await hostLume.noteFailure(
                message: message,
                recoveryHints: lumeRecoveryHints(for: message)
            )
        }

        /// Notes the setup confirmation for the host-Lume smoke and, when that lane is
        /// live, auto-confirms it on the next run-loop turn so the unattended scenario
        /// proceeds without desktop input.
        func handleProviderSetupConfirmation(
            _ request: WorkspaceProviderSetupConfirmationRequest,
            confirm: @escaping @MainActor () -> Void
        ) async {
            await hostLume.noteSetupConfirmationPresented(request)
            if hostLume.isEnabled {
                DispatchQueue.main.async {
                    confirm()
                }
            }
        }

        func noteProviderSetupStepChanged(_ presentation: WorkspaceProviderSetupProgressPresentation) async {
            await hostLume.noteSetupStepChanged(presentation)
        }

        // MARK: - Selection milestones (ContentView)

        func noteRepoTerminalAttached(sessionID: UUID, scopePath: String) {
            noteTerminalAttached(kind: .repo, sessionID: sessionID, scopePath: scopePath)
        }

        func noteWorkspaceTerminalAttached(sessionID: UUID, scopePath: String) {
            noteTerminalAttached(kind: .workspace, sessionID: sessionID, scopePath: scopePath)
        }

        private func noteTerminalAttached(
            kind: DesktopUISmokeSelectionKind,
            sessionID: UUID,
            scopePath: String
        ) {
            guard desktopUI.isEnabled else { return }
            Task { @MainActor in
                await desktopUI.noteTerminalSessionAttached(
                    kind: kind,
                    sessionID: sessionID,
                    scopePath: scopePath
                )
            }
        }

        func noteSurfaceFocused(sessionID: UUID) {
            guard desktopUI.isEnabled else { return }
            Task { @MainActor in
                await desktopUI.noteSurfaceFocused(sessionID: sessionID)
            }
        }

        /// Mount observer for the web main-content surface, nil unless the desktop-UI
        /// smoke is live so production web views carry no callback.
        var webSurfaceMountObserver: ((WebSource) -> Void)? {
            guard desktopUI.isEnabled else { return nil }
            let automation = desktopUI
            return { source in
                Task { await automation.noteWebSurfaceAttached(sourceName: source.name) }
            }
        }

        /// After an API-driven `workspace.create` that selected the new workspace, hand the walk's
        /// repo step to the external `repo.terminal` verb and then the reselect to `workspace.select`.
        /// This is the middle of the daily-driver walk — workspace → repo → workspace — and the app
        /// no longer drives any of it (#958). Only fires when both API drivers are live.
        func noteAPIWorkspaceCreateCompleted(
            repoID: UUID,
            workspaceID: UUID,
            repos: [Repo]
        ) {
            guard desktopUI.usesAPICreateDriver, desktopUI.usesAPISelectDriver else { return }
            guard
                let repo = repos.first(where: { $0.id == repoID }),
                let workspace = repos.flatMap(\.workspaces).first(where: { $0.id == workspaceID })
            else { return }
            Task { @MainActor in
                let attachBaselineBeforeRepoPark = desktopUI.terminalAttachCount
                let focusBaselineBeforeRepoPark = desktopUI.surfaceFocusCount
                await desktopUI.noteAwaitingAPIRepoTerminal(repo: repo)
                _ = await desktopUI.waitForTerminalAttach(
                    after: attachBaselineBeforeRepoPark,
                    timeout: .seconds(60)
                )
                _ = await desktopUI.waitForSurfaceFocus(
                    after: focusBaselineBeforeRepoPark,
                    timeout: .seconds(60)
                )
                await desktopUI.noteAwaitingAPISelect(workspace: workspace)
            }
        }

        // MARK: - Fixture continuity (ContentView)

        func waitForFixtureContinuitySeed() async {
            await UIFixtureContinuitySeeder.waitUntilSeeded()
        }
    }
#else
    @MainActor
    final class SmokeScenarioDriver: ObservableObject {
        init(environment: [String: String] = [:]) {}

        nonisolated static var isLumeFixtureEnabled: Bool { false }

        func driveScenariosIfNeeded(_ context: SmokeScenarioSidebarContext) async {}
        func driveHostLumeScenarioIfNeeded(_ context: SmokeScenarioSidebarContext) async {}
        func driveDesktopUIScenarioIfNeeded(_ context: SmokeScenarioSidebarContext) async {}
        func noteFailure(message: String) async {}
        func noteWorkspaceCreationPhase(message: String) async {}
        func noteWorkspacePersisted(_ result: WorkspaceProviderCreationResult) async {}
        func noteWorkspaceActive(_ workspace: Workspace) async {}
        func noteWorkspaceCreated(
            _ workspace: Workspace,
            sidebarWorkspaces: @MainActor () -> [Workspace]
        ) async {}
        func noteHostLumeLaunchReady() async {}
        func noteDesktopUILaunchReady() async {}
        func noteHostWorkspaceFailure(message: String) async {}
        func handleProviderSetupConfirmation(
            _ request: WorkspaceProviderSetupConfirmationRequest,
            confirm: @escaping @MainActor () -> Void
        ) async {}
        func noteProviderSetupStepChanged(_ presentation: WorkspaceProviderSetupProgressPresentation) async {}
        func noteRepoTerminalAttached(sessionID: UUID, scopePath: String) {}
        func noteWorkspaceTerminalAttached(sessionID: UUID, scopePath: String) {}
        func noteSurfaceFocused(sessionID: UUID) {}
        var webSurfaceMountObserver: ((WebSource) -> Void)? { nil }
        func noteAPIWorkspaceCreateCompleted(
            repoID: UUID,
            workspaceID: UUID,
            repos: [Repo]
        ) {}
        func waitForFixtureContinuitySeed() async {}
    }
#endif
