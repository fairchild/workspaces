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
    private var passes: SerialPasses?

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
        let passes = SerialPasses(
            first: {
                do {
                    try await indexer.launch()
                } catch {
                    log.error("conversation launch pass failed: \(String(describing: error), privacy: .public)")
                }
            },
            then: {
                do {
                    try await indexer.sync()
                } catch {
                    log.error("conversation index sync failed: \(String(describing: error), privacy: .public)")
                }
            }
        )
        self.passes = passes
        Task.detached(priority: .utility) { await passes.request() }
        let watcher = AgentLaunchRecordWatcher(
            directory: ConversationRecordsLocation.directory,
            directoryPermissions: ConversationRecordStore.directoryPermissions
        ) {
            Task.detached(priority: .utility) { await passes.request() }
        }
        watcher.start()
        self.watcher = watcher
    }
}

/// Runs passes one at a time: `first` once, then `then` for every later request. A request
/// that arrives while a pass runs folds into one more pass after it, so a steady stream of
/// record writes keeps at most one pass running and one waiting, and a sync never reads the
/// index while the launch rebuild is still writing it.
actor SerialPasses {
    private let first: @Sendable () async -> Void
    private let then: @Sendable () async -> Void
    private var ranFirst = false
    private var running = false
    private var requested = false

    init(first: @escaping @Sendable () async -> Void, then: @escaping @Sendable () async -> Void) {
        self.first = first
        self.then = then
    }

    func request() async {
        requested = true
        guard !running else { return }
        running = true
        while requested {
            requested = false
            if ranFirst {
                await then()
            } else {
                ranFirst = true
                await first()
            }
        }
        running = false
    }
}
