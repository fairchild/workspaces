import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// Regression surface for the workspace-creation-hang follow-up
/// (`backlog/workspace-creation-hang-root-cause_followup.md`).
///
/// These tests exercise the two concrete hypotheses PR #190 addressed:
/// 1. A debounced `ContentView.saveAccessTimestampChanges`-style `modelContext.save()`
///    Task firing concurrently with `SidebarWorkspaceController.createWorkspace`'s
///    upsert path on the same `ModelContext`.
/// 2. The rollback-on-save-failure path losing pending workspace inserts, which is
///    the bug PR #190's `insertedModelsArray.isEmpty` guard prevents.
///
/// A clean pass does not prove the production hang is fixed — these tests only
/// exercise unit-test conditions (in-memory `ModelContainer`, synthesized MainActor
/// scheduling). A live repro after shared-desktop isolation (P0 #3) is still the
/// ultimate confirmation. A failure here, however, is high-signal.
@Suite("WorkspaceCreationRace")
struct WorkspaceCreationRaceTests {
    @Test(
        "Debounced save Task racing with workspace creation preserves both writes without deadlock"
    )
    @MainActor
    func debouncedSaveDuringCreationPreservesBothWrites() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)
        try context.save()
        let initialTimestamp = repo.lastAccessedAt

        let workspaceService = MockWorkspaceService()
        workspaceService.createWorkspaceDelay = {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let controller = makeController(
            context: context,
            workspaceService: workspaceService,
            providers: [LocalWorkspaceProvider()]
        )

        async let createdWorkspace = controller.createWorkspace(
            from: repo,
            name: "feature-a",
            providerID: LocalWorkspaceProvider.identifier
        )

        let debouncedSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5))
            repo.lastAccessedAt = Date()
            try? await Task.sleep(for: .milliseconds(5))
            do {
                try context.save()
            } catch {
                if context.insertedModelsArray.isEmpty {
                    context.rollback()
                }
            }
        }

        let workspace = try await createdWorkspace
        await debouncedSave.value

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.count == 1)
        #expect(workspaces.first?.name == "feature-a")
        #expect(workspace.name == "feature-a")
        #expect(repo.lastAccessedAt != initialTimestamp)
    }

    @Test(
        "Unguarded rollback discards pending workspace insert — the bug PR #190 prevents"
    )
    @MainActor
    func unguardedRollbackDiscardsPendingInsert() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)
        try context.save()

        let partial = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            status: .active
        )
        context.insert(partial)

        #expect(!context.insertedModelsArray.isEmpty)
        #expect(context.insertedModelsArray.count == 1)

        context.rollback()

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.isEmpty)
        #expect(context.insertedModelsArray.isEmpty)
    }

    @Test(
        "Skipping rollback when inserts pend lets the next save commit the partial workspace"
    )
    @MainActor
    func skippedRollbackPreservesPendingInsertAcrossSave() async throws {
        let fixture = try makeModelContext()
        let context = fixture.context
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)
        try context.save()

        let partial = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            status: .active
        )
        context.insert(partial)

        #expect(!context.insertedModelsArray.isEmpty)

        try context.save()

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.count == 1)
        #expect(workspaces.first?.name == "feature-a")
        #expect(context.insertedModelsArray.isEmpty)
    }

    @MainActor
    private func makeModelContext() throws -> ModelContextFixture {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContextFixture(container: container, context: container.mainContext)
    }

    @MainActor
    private func makeController(
        context: ModelContext,
        workspaceService: MockWorkspaceService,
        providers: [any WorkspaceProviderProtocol]
    ) -> SidebarWorkspaceController {
        SidebarWorkspaceController(
            modelContext: context,
            workspaceService: workspaceService,
            workspaceProviderRegistry: WorkspaceProviderRegistry(providers: providers)
        )
    }
}

private struct ModelContextFixture {
    let container: ModelContainer
    let context: ModelContext
}

private final class MockWorkspaceService: WorkspaceServiceProtocol, @unchecked Sendable {
    var workspacesRootValue = URL(fileURLWithPath: "/tmp/workspaces")
    var workspacesRoot: URL {
        get async { workspacesRootValue }
    }

    var createWorkspaceDelay: @Sendable () async -> Void = {}

    func createWorkspace(
        repoName: String,
        repoLocalURL: URL,
        name: String,
        progress: WorkspaceCreationProgressHandler?
    ) async throws -> NewWorkspaceInfo {
        await createWorkspaceDelay()
        let sanitizedName = WorkspaceService.sanitizeWorkspaceNameComponent(name)
        return NewWorkspaceInfo(
            name: name,
            path:
                workspacesRootValue
                .appendingPathComponent(repoName, isDirectory: true)
                .appendingPathComponent(sanitizedName, isDirectory: true),
            gitBranch: "workspace/\(sanitizedName)"
        )
    }

    func archiveWorkspace(at workspaceURL: URL) async throws {}

    func deleteWorkspace(at workspaceURL: URL, deleteFiles: Bool) async throws {}

    func runLifecycleScript(
        _ scriptName: String,
        in directory: URL
    ) async throws -> WorkspaceService.ScriptResult {
        WorkspaceService.ScriptResult(exitCode: 0, stdout: "", stderr: "")
    }

    func getWorkspaceSize(at workspaceURL: URL) async throws -> Int64 { 0 }

    func sanitizeFilename(_ name: String) async -> String { name }
}
