import SwiftData
import SwiftUI
import WorkspaceManagerCore
import os.log

private let creationLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceCreation"
)

/// The create/archive/open actions the repo landing view offers, plus the New Workspace
/// sheet's presentation handshake. Distinct from the sidebar's creation path, which carries
/// per-repo progress, a stall watchdog, and automation confirmation results the landing view
/// has no surface for; only the shared mechanics live in `SidebarWorkspaceController`.
@MainActor
struct MainWindowLandingActionController {
    struct Dependencies {
        let repoForNewWorkspace: Binding<Repo?>
        let isPreparingNewWorkspaceSheet: Binding<Bool>
        let modelContext: ModelContext
        let workspaceService: any WorkspaceServiceProtocol
        let providerRegistry: WorkspaceProviderRegistry
        let providerSetupActionRunner: WorkspaceProviderSetupActionRunner
        let externalEditorService: any ExternalEditorServiceProtocol
        let webSources: @MainActor () -> [WebSource]
        let retireTerminalSessions: @MainActor (HostTerminalSessionKey) async throws -> Void
        let selectWorkspace: @MainActor (Workspace) -> Void
        let selectWebSource: @MainActor (WebSource) -> Void
        let abandonPendingRemoteConnection: @MainActor (String) -> Void
        let seedEnvironmentStateIfNeeded: @MainActor () async -> Bool
        let prepareEnvironmentStateForPresentation: @MainActor () -> Void
        let refreshEnvironmentState: @MainActor (String) async -> Void
        let environmentOptionCount: @MainActor (Repo) -> Int
        let lumeStateDescription: @MainActor () -> String
        let presentLandingError: @MainActor (String) -> Void
        let presentOpenInEditorError: @MainActor (Error) -> Void
    }

    let dependencies: Dependencies

    private var workspaceController: SidebarWorkspaceController {
        SidebarWorkspaceController(
            modelContext: dependencies.modelContext,
            workspaceService: dependencies.workspaceService,
            workspaceProviderRegistry: dependencies.providerRegistry,
            retireTerminalSessions: dependencies.retireTerminalSessions
        )
    }

    /// Open the New Workspace sheet for `repo`. The sheet is bound to the repo, so it is set
    /// before the environment options finish resolving and the options stream in behind the
    /// `isPreparing` flag — the sheet appears at click speed rather than at provider speed.
    func presentNewWorkspaceSheet(for repo: Repo) async {
        InvestigationDiagnostics.emitSheet(
            phase: "landing_sheet_flow_started",
            fields: ["repo_id": repo.id.uuidString]
        )
        let attemptID = PerformanceSignposts.beginNewWorkspaceSheetReady(trigger: "landing")

        if await dependencies.seedEnvironmentStateIfNeeded() {
            InvestigationDiagnostics.emitSheet(
                phase: "landing_fixture_seeded",
                fields: ["repo_id": repo.id.uuidString]
            )
            dependencies.repoForNewWorkspace.wrappedValue = repo
            InvestigationDiagnostics.emitSheet(
                phase: "landing_sheet_context_set",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "option_count": "\(dependencies.environmentOptionCount(repo))",
                ]
            )
            PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
                attemptID: attemptID,
                outcome: "success"
            )
        }

        dependencies.prepareEnvironmentStateForPresentation()
        dependencies.repoForNewWorkspace.wrappedValue = repo
        dependencies.isPreparingNewWorkspaceSheet.wrappedValue = true
        InvestigationDiagnostics.emitSheet(
            phase: "landing_sheet_context_set",
            fields: [
                "repo_id": repo.id.uuidString,
                "option_count": "\(dependencies.environmentOptionCount(repo))",
            ]
        )
        PerformanceSignposts.endNewWorkspaceSheetReadyIfNeeded(
            attemptID: attemptID,
            outcome: "success"
        )

        Task { @MainActor in
            defer {
                dependencies.isPreparingNewWorkspaceSheet.wrappedValue = false
            }
            await dependencies.refreshEnvironmentState("landing_sheet_open")
            InvestigationDiagnostics.emitSheet(
                phase: "landing_environment_refresh_completed",
                fields: [
                    "repo_id": repo.id.uuidString,
                    "lume_state": dependencies.lumeStateDescription(),
                    "option_count": "\(dependencies.environmentOptionCount(repo))",
                ]
            )
        }
    }

    /// Create a workspace from the landing sheet, running provider setup first when the
    /// provider needs it. Both setup arms create with `skipSetup: true` so the workspace is
    /// made exactly once whether or not setup was intercepted.
    func createWorkspace(
        repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS?
    ) async {
        do {
            guard let provider = dependencies.providerRegistry.provider(for: providerID) else {
                dependencies.presentLandingError("Workspace provider '\(providerID)' is not registered.")
                return
            }

            try await dependencies.providerSetupActionRunner.run(
                provider: provider,
                action: .createWorkspace(name: name, guestOS: guestOS)
            ) {
                await createWorkspaceReportingFailure(
                    repo: repo,
                    name: name,
                    nameSource: nameSource,
                    providerID: providerID,
                    guestOS: guestOS
                )
            } perform: {
                await createWorkspaceReportingFailure(
                    repo: repo,
                    name: name,
                    nameSource: nameSource,
                    providerID: providerID,
                    guestOS: guestOS
                )
            }
        } catch {
            dependencies.presentLandingError("Failed to create workspace: \(error.localizedDescription)")
        }
    }

    private func createWorkspaceReportingFailure(
        repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS?
    ) async {
        do {
            try await createWorkspace(
                repo: repo,
                name: name,
                nameSource: nameSource,
                providerID: providerID,
                guestOS: guestOS,
                skipSetup: true
            )
        } catch {
            dependencies.presentLandingError("Failed to create workspace: \(error.localizedDescription)")
        }
    }

    func createWorkspace(
        repo: Repo,
        name: String,
        nameSource: WorkspaceNameSource,
        providerID: String,
        guestOS: WorkspaceGuestOS?,
        skipSetup: Bool
    ) async throws {
        creationLog.info(
            "createWorkspaceFromLanding: repo=\(repo.name) provider=\(providerID) skipSetup=\(skipSetup)"
        )
        let workspace = try await workspaceController.createWorkspace(
            from: repo,
            name: name,
            nameSource: nameSource,
            providerID: providerID,
            guestOS: guestOS,
            progress: { _ in },
            onPersisted: nil
        )
        creationLog.info("createWorkspaceFromLanding: workspace created successfully")

        if skipSetup {
            dependencies.abandonPendingRemoteConnection("workspace_created")
            dependencies.selectWorkspace(workspace)
        }
    }

    func archiveWorkspace(_ workspace: Workspace) async {
        do {
            try await workspaceController.archive(workspace)
        } catch {
            dependencies.presentLandingError("Failed to archive workspace: \(error.localizedDescription)")
        }
    }

    func openWorkspaceInDefaultEditor(_ workspace: Workspace) {
        do {
            try OpenInEditorShortcutFlow.perform(
                target: .project(rootURL: workspace.workspaceURL),
                editorID: nil,
                externalEditorService: dependencies.externalEditorService,
                trigger: .uiPrimaryAction
            )
        } catch {
            dependencies.presentOpenInEditorError(error)
        }
    }

    /// Insert a web source and select it. A validation or persistence failure rolls the
    /// context back, so a rejected URL never leaves a half-inserted source behind.
    func addWebSource(
        rawURL: String,
        displayName: String,
        additionalAllowedDomainsRaw: String,
        target: WebSourceCreationTarget
    ) {
        do {
            let source = try WebSourceCreationSupport.makeSource(
                rawURL: rawURL,
                displayName: displayName,
                additionalAllowedDomainsRaw: additionalAllowedDomainsRaw,
                target: target,
                existingSources: dependencies.webSources()
            )

            dependencies.modelContext.insert(source)
            try dependencies.modelContext.save()
            dependencies.selectWebSource(source)
        } catch {
            if let validationError = error as? WebSourceValidationError {
                if let description = validationError.errorDescription {
                    dependencies.presentLandingError(description)
                }
            } else {
                dependencies.presentLandingError(error.localizedDescription)
            }
            dependencies.modelContext.rollback()
        }
    }
}
