//
//  MainWindowHotSpotPerfTests.swift
//  WorkspaceManagerAppTests
//
//  Opt-in performance scenarios for main-window hot spots that are hard to
//  isolate from ordinary unit tests: sidebar status aggregation bursts. Results
//  are written as JSON for scripts/main-window-hotspots-baseline.py.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite(
    "MainWindowHotSpotPerf",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_PERF_RUN"] == "1")
)
@MainActor
struct MainWindowHotSpotPerfTests {
    @Test("main_window_agent_activity_burst: sidebar status aggregation latency")
    func agentActivityBurstSidebarLatency() throws {
        let fixture = makeSidebarFixture(repoCount: 10, workspacesPerRepo: 2, repoSessionCount: 10)
        let presentation = SidebarWorkspacePresentationController()
        let aggregator = WorkspaceStatusAggregator()
        let registry = WorkspaceProviderRegistry(providers: [])
        let normalize: (URL) -> String = { url in
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }

        var statuses = fixture.statuses
        let statusSessionIDs = Array(statuses.keys)
        let refreshes = 1_000
        var sidebarSamples: [Double] = []
        sidebarSamples.reserveCapacity(refreshes)
        var dropdownSamples: [Double] = []
        dropdownSamples.reserveCapacity(refreshes)

        for iteration in 0..<refreshes {
            if let sessionID = statusSessionIDs[safe: iteration % statusSessionIDs.count],
                var status = statuses[sessionID]
            {
                status.lastEventAt = Date()
                status.run =
                    iteration % 5 == 0
                    ? .awaitingInput(reason: .permissionPrompt)
                    : .runningTool(
                        name: "Read",
                        detail: "fixture-\(iteration)"
                    )
                statuses[sessionID] = status
            }

            let started = DispatchTime.now().uptimeNanoseconds
            let workspaceInputs: [WorkspaceStatusAggregator.WorkspaceInput] =
                fixture.repos
                .flatMap(\.workspaces)
                .map { workspace in
                    let key = presentation.sessionKey(
                        for: workspace,
                        registry: registry,
                        normalizePath: normalize
                    )
                    let status = presentation.freshestAgentStatus(
                        for: key,
                        sessions: fixture.sessions,
                        agentStatusBySessionID: statuses
                    )
                    return WorkspaceStatusAggregator.WorkspaceInput(
                        workspaceID: workspace.id,
                        repoID: workspace.sourceRepo?.id,
                        lastAccessedAt: workspace.lastAccessedAt,
                        status: status
                    )
                }

            let repoInputs: [WorkspaceStatusAggregator.RepoInput] = fixture.repos.map { repo in
                let key = HostTerminalSessionKey.repoPath(normalize(repo.localURL))
                let status = presentation.freshestAgentStatus(
                    for: key,
                    sessions: fixture.sessions,
                    agentStatusBySessionID: statuses
                )
                return WorkspaceStatusAggregator.RepoInput(
                    repoID: repo.id,
                    lastAccessedAt: repo.lastAccessedAt,
                    status: status
                )
            }

            aggregator.update(workspaces: workspaceInputs, repos: repoInputs)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            sidebarSamples.append(Double(elapsed) / 1_000_000.0)

            let dropdownStarted = DispatchTime.now().uptimeNanoseconds
            _ = AttentionSummaryResolver.resolve(
                attentionItems: aggregator.attentionItems,
                repos: fixture.repos
            )
            let dropdownElapsed = DispatchTime.now().uptimeNanoseconds - dropdownStarted
            dropdownSamples.append(Double(dropdownElapsed) / 1_000_000.0)
        }

        let sidebarStats = summarize(sidebarSamples, unit: "ms")
        let dropdownStats = summarize(dropdownSamples, unit: "ms")
        try writeResult(
            [
                "scenario": "main_window_agent_activity_burst",
                "refreshes": refreshes,
                "repo_count": fixture.repos.count,
                "workspace_count": fixture.repos.flatMap(\.workspaces).count,
                "session_count": fixture.sessions.count,
                "metrics": [
                    "main_window_agent_activity_burst_sidebar_latency_ms": sidebarStats,
                    "main_window_attention_dropdown_resolution_ms": dropdownStats,
                ],
            ],
            scenario: "main_window_agent_activity_burst"
        )

        #expect(sidebarStats["median"] as? Double ?? .infinity < 1_000)
        #expect(dropdownStats["median"] as? Double ?? .infinity < 1_000)
    }

    private struct SidebarFixture {
        let repos: [Repo]
        let sessions: [HostTerminalSession]
        let statuses: [UUID: AgentSessionStatus]
    }

    private func makeSidebarFixture(
        repoCount: Int,
        workspacesPerRepo: Int,
        repoSessionCount: Int
    ) -> SidebarFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-main-window-perf", isDirectory: true)
        var repos: [Repo] = []
        var sessions: [HostTerminalSession] = []
        var statuses: [UUID: AgentSessionStatus] = [:]

        for repoIndex in 0..<repoCount {
            let repoURL = root.appendingPathComponent("repo-\(repoIndex)", isDirectory: true)
            let repo = Repo(name: "repo-\(repoIndex)", localPath: repoURL, lastAccessedAt: Date())
            var workspaces: [Workspace] = []

            for workspaceIndex in 0..<workspacesPerRepo {
                let workspaceURL = repoURL.appendingPathComponent("workspace-\(workspaceIndex)", isDirectory: true)
                let workspace = Workspace(
                    name: "workspace-\(repoIndex)-\(workspaceIndex)",
                    path: workspaceURL,
                    sourceRepo: repo,
                    lastAccessedAt: Date().addingTimeInterval(Double(-(repoIndex * 10 + workspaceIndex)))
                )
                workspaces.append(workspace)

                let session = HostTerminalSession(
                    key: .hostPath(normalize(workspaceURL)),
                    directory: workspaceURL
                )
                sessions.append(session)
                statuses[session.id] = AgentSessionStatus(
                    hostSessionID: session.id,
                    kind: .claudeCode,
                    cwd: workspaceURL.path,
                    run: workspaceIndex % 2 == 0
                        ? .thinking
                        : .runningTool(name: "Read", detail: nil),
                    lastEventAt: Date().addingTimeInterval(Double(-(workspaceIndex + repoIndex))),
                    hookActive: true
                )
            }

            repo.workspaces = workspaces
            repos.append(repo)
        }

        for repo in repos.prefix(repoSessionCount) {
            let session = HostTerminalSession(
                key: .repoPath(normalize(repo.localURL)),
                directory: repo.localURL
            )
            sessions.append(session)
            statuses[session.id] = AgentSessionStatus(
                hostSessionID: session.id,
                kind: .claudeCode,
                cwd: repo.localURL.path,
                run: .idle,
                lastEventAt: Date(),
                hookActive: true
            )
        }

        return SidebarFixture(repos: repos, sessions: sessions, statuses: statuses)
    }

    private func normalize(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func summarize(_ samples: [Double], unit: String) -> [String: Any] {
        guard !samples.isEmpty else {
            return [
                "count": 0,
                "min": 0.0,
                "median": 0.0,
                "mean": 0.0,
                "max": 0.0,
                "p95": 0.0,
                "unit": unit,
            ]
        }

        return [
            "count": samples.count,
            "min": samples.min() ?? 0.0,
            "median": percentile(samples, 50),
            "mean": samples.reduce(0, +) / Double(samples.count),
            "max": samples.max() ?? 0.0,
            "p95": percentile(samples, 95),
            "unit": unit,
        ]
    }

    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        guard sorted.count > 1 else { return sorted.first ?? 0.0 }
        let rank = (Double(sorted.count - 1) * p) / 100.0
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        if lower == upper { return sorted[lower] }
        let lowerWeight = Double(upper) - rank
        let upperWeight = rank - Double(lower)
        return sorted[lower] * lowerWeight + sorted[upper] * upperWeight
    }

    private func writeResult(_ payload: [String: Any], scenario: String) throws {
        let url = resultURL(scenario: scenario)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func resultURL(scenario: String) -> URL {
        if let override = ProcessInfo.processInfo.environment["WORKSPACES_PERF_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-perf-\(scenario)-\(Int(Date().timeIntervalSince1970))")
            .appendingPathComponent("result.json")
    }

}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
