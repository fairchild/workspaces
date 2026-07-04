//
//  TerminalRestoreCoordinator.swift
//  WorkspaceManager
//
//  Drives cold-start restore planning: reads the durable continuity read model,
//  pre-probes tmux liveness concurrently (bridging the async probe to the
//  planner's synchronous liveness closure), and returns a decided RestorePlan.
//  The SwiftData-derived RestoreTargetIndex is built on the main actor and passed
//  in as a Sendable snapshot, so this coordinator stays off the main actor.
//

import Foundation
import WorkspaceManagerCore

/// Shared path normalization for restore resolution — expands `~`, standardizes,
/// and resolves symlinks, matching `ContentView.normalizePath` so the index the
/// builder produces and the paths the resolver compares are normalized alike.
enum RestorePathNormalization {
    static let normalize: @Sendable (String) -> String = { rawPath in
        let expanded = NSString(string: rawPath).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct TerminalRestoreCoordinator: Sendable {
    let localStateStore: LocalStateStore
    let tmuxProbe: TmuxSessionProbe
    let transcriptResumability: ClaudeTranscriptResumability
    let normalizePath: @Sendable (String) -> String

    init(
        localStateStore: LocalStateStore,
        tmuxProbe: TmuxSessionProbe = TmuxSessionProbe(),
        transcriptResumability: ClaudeTranscriptResumability = ClaudeTranscriptResumability(),
        normalizePath: @escaping @Sendable (String) -> String = RestorePathNormalization.normalize
    ) {
        self.localStateStore = localStateStore
        self.tmuxProbe = tmuxProbe
        self.transcriptResumability = transcriptResumability
        self.normalizePath = normalizePath
    }

    /// Read the previous run's active sessions + latest layout, pre-probe tmux
    /// liveness, and produce a fully-decided plan. Store read failures degrade to
    /// an empty plan rather than throwing.
    func makePlan(index: RestoreTargetIndex) async -> RestorePlan {
        let rows = (try? await localStateStore.fetchPreviousRunSessions(limit: 100)) ?? []
        let layout = (try? await localStateStore.fetchLatestLayoutSnapshot()) ?? nil

        let liveNames = await probeLiveTmuxSessions(Set(rows.compactMap(\.tmuxSessionName)))

        let resolver = TerminalRestoreTargetResolver(index: index, normalizePath: normalizePath)
        let planner = TerminalRestorePlanner(
            resolveTarget: resolver.asResolver(),
            isTmuxSessionAlive: { liveNames.contains($0) },
            isTranscriptResumable: transcriptResumability.asCheck()
        )
        return planner.plan(rows: rows, layout: layout)
    }

    /// Fan out `has-session` probes concurrently and collect the live names, so
    /// the planner receives a pure synchronous membership test.
    private func probeLiveTmuxSessions(_ names: Set<String>) async -> Set<String> {
        guard !names.isEmpty else { return [] }
        let probe = tmuxProbe
        return await withTaskGroup(of: (String, Bool).self) { group in
            for name in names {
                group.addTask { (name, await probe.isSessionAlive(name)) }
            }
            var live: Set<String> = []
            for await (name, alive) in group where alive {
                live.insert(name)
            }
            return live
        }
    }
}
