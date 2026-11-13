//
//  AgentLaunchRecordWatcher.swift
//  WorkspaceManager
//
//  Says when a record has landed in a directory of records: the CLI's launch records for a
//  window, and Conversation records for the app's conversation index. A record lands by
//  atomic rename, which is a write to the directory, so one kernel event covers it. Bursts
//  are coalesced: a launcher fanning out workers should cost one pass, not one per worker.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "AgentLaunchRecordWatcher")

@MainActor
final class AgentLaunchRecordWatcher {
    private let directory: URL
    private let directoryPermissions: Int?
    private let onChange: @MainActor () -> Void
    private let coalescing: Duration
    private let maxWait: Duration
    private var source: DispatchSourceFileSystemObject?
    private var pendingPass: Task<Void, Never>?
    private var firstUnpassedEvent: ContinuousClock.Instant?

    /// A pass runs `coalescing` after the last event of a burst, and no later than `maxWait`
    /// after its first, so writes that never pause still reach the window.
    init(
        directory: URL,
        directoryPermissions: Int? = nil,
        coalescing: Duration = .milliseconds(300),
        maxWait: Duration = .seconds(2),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.directory = directory
        self.directoryPermissions = directoryPermissions
        self.coalescing = coalescing
        self.maxWait = maxWait
        self.onChange = onChange
    }

    /// The directory is created here because it may not exist yet on a machine that has never
    /// launched from the CLI, and an event source needs something to open. It is created with
    /// `directoryPermissions` when given, since whoever makes it first sets its mode.
    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: directoryPermissions.map { [.posixPermissions: $0] }
        )
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            log.notice("Not watching records: could not open \(self.directory.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated { self?.handle(source?.data ?? []) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        pendingPass?.cancel()
        pendingPass = nil
        firstUnpassedEvent = nil
        source?.cancel()
        source = nil
    }

    /// A directory deleted or moved away is no longer where records land, and the descriptor
    /// would go on watching it, so the watch starts over on the path.
    private func handle(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename]) {
            source?.cancel()
            source = nil
            start()
        }
        schedulePass()
    }

    private func schedulePass() {
        let now = ContinuousClock.now
        let first = firstUnpassedEvent ?? now
        firstUnpassedEvent = first
        let delay = max(.zero, min(coalescing, first + maxWait - now))
        pendingPass?.cancel()
        pendingPass = Task { [weak self, onChange] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.firstUnpassedEvent = nil
            onChange()
        }
    }
}
