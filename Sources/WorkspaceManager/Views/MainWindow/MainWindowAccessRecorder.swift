import Foundation
import SwiftData
import WorkspaceManagerCore
import os.log

private let accessRecorderLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceCreation"
)

@MainActor
struct MainWindowAccessRecorder {
    enum SaveFailureResolution: Equatable {
        case rolledBack
        case preservedPendingInserts(Int)
    }

    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?

    init(saveDelay: Duration = .milliseconds(500)) {
        self.saveDelay = saveDelay
    }

    mutating func record(repo: Repo, modelContext: ModelContext) {
        repo.lastAccessedAt = Date()
        scheduleSave(modelContext: modelContext)
    }

    mutating func record(workspace: Workspace, modelContext: ModelContext) {
        let accessDate = Date()
        workspace.lastAccessedAt = accessDate
        workspace.sourceRepo?.lastAccessedAt = accessDate
        scheduleSave(modelContext: modelContext)
    }

    mutating func record(webSource: WebSource, modelContext: ModelContext) {
        let accessDate = Date()
        webSource.lastAccessedAt = accessDate
        webSource.ownerRepo?.lastAccessedAt = accessDate
        scheduleSave(modelContext: modelContext)
    }

    mutating func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    @discardableResult
    static func savePendingChanges(modelContext: ModelContext) -> SaveFailureResolution? {
        do {
            try modelContext.save()
            return nil
        } catch {
            return resolveSaveFailure(modelContext: modelContext)
        }
    }

    @discardableResult
    static func resolveSaveFailure(modelContext: ModelContext) -> SaveFailureResolution {
        let pendingInsertCount = modelContext.insertedModelsArray.count
        if pendingInsertCount == 0 {
            accessRecorderLog.warning(
                "saveAccessTimestampChanges: save failed, rolling back (no pending inserts)"
            )
            modelContext.rollback()
            return .rolledBack
        }

        accessRecorderLog.error(
            "saveAccessTimestampChanges: save failed with \(pendingInsertCount) pending inserts - skipping rollback to preserve workspace creation"
        )
        return .preservedPendingInserts(pendingInsertCount)
    }

    private mutating func scheduleSave(modelContext: ModelContext) {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            Self.savePendingChanges(modelContext: modelContext)
        }
    }
}
