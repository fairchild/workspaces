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

/// UserDefaults key recording the prior run a restore banner action (Restore or
/// Dismiss) already handled, so later launches that select the same prior run
/// don't re-offer it (issue #783 #4 — banner frequency guard).
enum TerminalRestoreBannerStorage {
    static let handledRunIDKey = "terminalRestoreHandledRunID"
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
        let previousRunID = (try? await localStateStore.fetchPreviousRunID()) ?? nil

        let liveNames = await probeLiveTmuxSessions(Set(rows.compactMap(\.tmuxSessionName)))
        let reportedHolders = await probeReportedHolders(
            of: sharedLiveNames(in: rows.filter { $0.endedAt == nil && $0.isActive }, liveNames: liveNames)
        )

        let resolver = TerminalRestoreTargetResolver(index: index, normalizePath: normalizePath)
        let planner = TerminalRestorePlanner(
            resolveTarget: resolver.asResolver(),
            isTmuxSessionAlive: { liveNames.contains($0) },
            reportedTmuxHolder: { reportedHolders[$0] },
            isTranscriptResumable: transcriptResumability.asCheck(),
            newestTranscriptID: transcriptResumability.asIdentityResolver()
        )
        return planner.plan(rows: rows, layout: layout, previousRunID: previousRunID)
    }

    private func sharedLiveNames(in rows: [TerminalSessionContinuityRow], liveNames: Set<String>) -> Set<String> {
        TmuxSessionNameSharing.sharedNames(
            in: rows.compactMap { row in
                guard let name = row.tmuxSessionName, liveNames.contains(name) else { return nil }
                return TmuxSessionNameSharing.Claim(hostSessionID: row.hostSessionID, tmuxSessionName: name)
            })
    }

    /// Ask each shared live session which host session its environment reports, so the
    /// planner can leave the session with the tab its processes belong to.
    private func probeReportedHolders(of names: Set<String>) async -> [String: UUID] {
        guard !names.isEmpty else { return [:] }
        let probe = tmuxProbe
        return await withTaskGroup(of: (String, UUID?).self) { group in
            for name in names {
                group.addTask { (name, await probe.reportedHostSessionID(forSessionNamed: name)) }
            }
            var holders: [String: UUID] = [:]
            for await (name, holder) in group {
                holders[name] = holder
            }
            return holders
        }
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
