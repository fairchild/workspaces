//
//  ConversationRecordsLifecycle.swift
//  WorkspaceManager
//
//  The app's side of Conversation records: where they live for this run, the one-time
//  migration and index rebuild at launch, and the watch that keeps the index level with
//  records the CLI and the SessionStart hook write while the app runs.
//

import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "ConversationRecords")

enum ConversationRecordsLocation {
    /// Resolved once, from the environment the app launched with. The app clears tile-scoped
    /// keys from its own environment at startup, and this is one of them, so
    /// `WorkspaceManagerApp.init` reads it before that happens. A run isolated with
    /// `WORKSPACES_CONVERSATIONS_DIR` keeps its records apart that way.
    static let resolution: (directory: URL, isExplicit: Bool) = {
        let environment = ProcessInfo.processInfo.environment
        return (
            ConversationRecordStore.resolvedDirectory(environment: environment),
            !(environment[ConversationRecordStore.directoryEnvironmentKey] ?? "").isEmpty
        )
    }()

    static var directory: URL { resolution.directory }
}

@MainActor
final class ConversationRecordsLifecycle {
    static let shared = ConversationRecordsLifecycle()

    private var watcher: AgentLaunchRecordWatcher?
    private var indexer: ConversationIndexer?

    private init() {}

    /// A UI fixture run seeds synthetic tiles into its own database, and the migration would
    /// copy their ids into the shared record directory unless the run names its own.
    nonisolated static func isAllowed(environment: [String: String]) -> Bool {
        environment["WORKSPACES_UI_FIXTURE"] != "1" || ConversationRecordsLocation.resolution.isExplicit
    }

    func start(localStateStore: LocalStateStore?) {
        guard watcher == nil, let localStateStore else { return }
        let indexer = ConversationIndexer(
            records: ConversationRecordStore(directory: ConversationRecordsLocation.directory),
            localState: localStateStore
        )
        self.indexer = indexer
        Task.detached(priority: .utility) {
            do {
                try await indexer.launch()
            } catch {
                log.error("conversation index rebuild failed: \(String(describing: error), privacy: .public)")
            }
        }
        let watcher = AgentLaunchRecordWatcher(directory: ConversationRecordsLocation.directory) {
            Task.detached(priority: .utility) {
                do {
                    try await indexer.sync()
                } catch {
                    log.error("conversation index sync failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        watcher.start()
        self.watcher = watcher
    }
}
