import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("MainWindowAccessRecorder")
struct MainWindowAccessRecorderTests {
    @Test("Recording access updates repo workspace and web source timestamps")
    func recordingAccessUpdatesTimestamps() throws {
        let fixture = try makeModelContext()
        let repo = Repo(
            name: "alpha",
            localPath: URL(fileURLWithPath: "/tmp/alpha"),
            lastAccessedAt: Date(timeIntervalSince1970: 10)
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo,
            lastAccessedAt: Date(timeIntervalSince1970: 20)
        )
        let webSource = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            lastAccessedAt: Date(timeIntervalSince1970: 30),
            sourceRepo: repo
        )
        fixture.context.insert(repo)
        fixture.context.insert(workspace)
        fixture.context.insert(webSource)
        try fixture.context.save()

        var recorder = MainWindowAccessRecorder(saveDelay: .milliseconds(1))
        recorder.record(repo: repo, modelContext: fixture.context)
        #expect(repo.lastAccessedAt > Date(timeIntervalSince1970: 10))

        recorder.record(workspace: workspace, modelContext: fixture.context)
        #expect(workspace.lastAccessedAt > Date(timeIntervalSince1970: 20))
        #expect(repo.lastAccessedAt == workspace.lastAccessedAt)

        recorder.record(webSource: webSource, modelContext: fixture.context)
        #expect(webSource.lastAccessedAt > Date(timeIntervalSince1970: 30))
        #expect(repo.lastAccessedAt == webSource.lastAccessedAt)
        recorder.cancelPendingSave()
    }

    @Test("Debounced save persists recorded access")
    func debouncedSavePersistsRecordedAccess() async throws {
        let fixture = try makeModelContext()
        let repo = Repo(
            name: "alpha",
            localPath: URL(fileURLWithPath: "/tmp/alpha"),
            lastAccessedAt: Date(timeIntervalSince1970: 10)
        )
        fixture.context.insert(repo)
        try fixture.context.save()

        var recorder = MainWindowAccessRecorder(saveDelay: .milliseconds(1))
        recorder.record(repo: repo, modelContext: fixture.context)

        let fetchedRepos = try await fetchReposAfterDebouncedSave(from: fixture.container)
        #expect(fetchedRepos.count == 1)
        #expect(fetchedRepos.first?.lastAccessedAt ?? .distantPast > Date(timeIntervalSince1970: 10))
    }

    @Test("Flushing pending save persists access without waiting for debounce")
    func flushingPendingSavePersistsRecordedAccess() throws {
        let fixture = try makeModelContext()
        let repo = Repo(
            name: "alpha",
            localPath: URL(fileURLWithPath: "/tmp/alpha"),
            lastAccessedAt: Date(timeIntervalSince1970: 10)
        )
        fixture.context.insert(repo)
        try fixture.context.save()

        var recorder = MainWindowAccessRecorder(saveDelay: .seconds(60))
        recorder.record(repo: repo, modelContext: fixture.context)
        let result = recorder.flushPendingSave(modelContext: fixture.context)

        let freshContext = ModelContext(fixture.container)
        let fetchedRepos = try freshContext.fetch(FetchDescriptor<Repo>())
        #expect(result == nil)
        #expect(fetchedRepos.count == 1)
        #expect(fetchedRepos.first?.lastAccessedAt ?? .distantPast > Date(timeIntervalSince1970: 10))
    }

    @Test("Save failure rollback is skipped when inserts are pending")
    func saveFailureRollbackSkipsPendingInserts() throws {
        let fixture = try makeModelContext()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        fixture.context.insert(repo)
        try fixture.context.save()

        let pendingWorkspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        fixture.context.insert(pendingWorkspace)

        let result = MainWindowAccessRecorder.resolveSaveFailure(modelContext: fixture.context)

        #expect(result == .preservedPendingInserts(1))
        #expect(!fixture.context.insertedModelsArray.isEmpty)
    }

    @Test("Save failure rolls back when no inserts are pending")
    func saveFailureRollsBackWithoutPendingInserts() throws {
        let fixture = try makeModelContext()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        fixture.context.insert(repo)
        try fixture.context.save()
        repo.name = "changed"

        let result = MainWindowAccessRecorder.resolveSaveFailure(modelContext: fixture.context)

        #expect(result == .rolledBack)
        #expect(fixture.context.insertedModelsArray.isEmpty)
    }

    private func makeModelContext() throws -> ModelContextFixture {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContextFixture(container: container, context: container.mainContext)
    }

    private func fetchReposAfterDebouncedSave(from container: ModelContainer) async throws -> [Repo] {
        let baseline = Date(timeIntervalSince1970: 10)
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(20))
            let freshContext = ModelContext(container)
            let fetchedRepos = try freshContext.fetch(FetchDescriptor<Repo>())
            if fetchedRepos.first?.lastAccessedAt ?? .distantPast > baseline {
                return fetchedRepos
            }
        }

        let freshContext = ModelContext(container)
        return try freshContext.fetch(FetchDescriptor<Repo>())
    }
}

private struct ModelContextFixture {
    let container: ModelContainer
    let context: ModelContext
}
