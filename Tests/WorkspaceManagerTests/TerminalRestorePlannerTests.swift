import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TerminalRestorePlanner")
struct TerminalRestorePlannerTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fixtures

    private func makeRow(
        hostSessionID: UUID = UUID(),
        targetKind: String = "repo",
        directoryPath: String = "/repo",
        terminalMode: String = "ghostty_managed_splits",
        tmuxSessionName: String? = nil,
        isActive: Bool = true,
        endedAt: Date? = nil,
        agentSessionID: String? = nil,
        agentKind: String? = nil,
        agentCwd: String? = nil
    ) -> TerminalSessionContinuityRow {
        TerminalSessionContinuityRow(
            hostSessionID: hostSessionID,
            sessionKey: "repoPath(\(directoryPath))",
            targetKind: targetKind,
            targetID: nil,
            targetPath: directoryPath,
            backendIdentifier: nil,
            backendInstanceID: nil,
            directoryPath: directoryPath,
            terminalMode: terminalMode,
            tmuxSessionName: tmuxSessionName,
            customCommandPresent: false,
            isActive: isActive,
            createdAt: Self.baseDate,
            lastSeenAt: Self.baseDate,
            endedAt: endedAt,
            agentSessionID: agentSessionID,
            agentKind: agentKind,
            agentRunState: agentSessionID == nil ? nil : "running_tool",
            agentCwd: agentCwd,
            agentModelDisplayName: agentSessionID == nil ? nil : "Claude",
            agentEventAt: agentSessionID == nil ? nil : Self.baseDate
        )
    }

    private func makePlanner(
        resolve: @escaping TerminalRestorePlanner.TargetResolver = { row in
            ResolvedRestoreTarget(
                key: .repoPath(row.directoryPath),
                rootDirectory: URL(fileURLWithPath: row.directoryPath)
            )
        },
        tmuxAlive: @escaping TerminalRestorePlanner.TmuxLivenessProbe = { _ in false },
        transcriptResumable: @escaping TerminalRestorePlanner.TranscriptResumabilityCheck = { _, _ in false },
        directoryExists: @escaping TerminalRestorePlanner.DirectoryExistenceCheck = { _ in true }
    ) -> TerminalRestorePlanner {
        TerminalRestorePlanner(
            resolveTarget: resolve,
            isTmuxSessionAlive: tmuxAlive,
            isTranscriptResumable: transcriptResumable,
            directoryExists: directoryExists
        )
    }

    // MARK: Tests

    @Test("Ended or inactive rows are excluded")
    func endedOrInactiveExcluded() {
        let planner = makePlanner()
        let plan = planner.plan(
            rows: [
                makeRow(endedAt: Self.baseDate),
                makeRow(isActive: false),
            ],
            layout: nil
        )
        #expect(plan.surfaces.isEmpty)
    }

    @Test("Rows whose target no longer resolves are dropped")
    func unresolvedTargetExcluded() {
        let planner = makePlanner(resolve: { _ in nil })
        let plan = planner.plan(rows: [makeRow()], layout: nil)
        #expect(plan.surfaces.isEmpty)
    }

    @Test("Live tmux session reattaches and takes precedence over the resume rung")
    func liveTmuxReattaches() throws {
        let planner = makePlanner(
            tmuxAlive: { $0 == "wm-repo-abcd1234" },
            // Would pick resume if the ladder fell through — proves tmux short-circuits.
            transcriptResumable: { _, _ in true }
        )
        let row = makeRow(
            tmuxSessionName: "wm-repo-abcd1234",
            agentSessionID: "claude-session-1",
            agentKind: "claudeCode",
            agentCwd: "/repo"
        )
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .reattachTmux(sessionName: "wm-repo-abcd1234"))
    }

    @Test("A present Claude transcript resumes in the recorded cwd")
    func transcriptPresentResumes() throws {
        let planner = makePlanner(transcriptResumable: { id, cwd in id == "claude-session-2" && cwd == "/repo" })
        let row = makeRow(agentSessionID: "claude-session-2", agentKind: "claudeCode", agentCwd: "/repo")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .resumeClaude(agentSessionID: "claude-session-2"))
        #expect(surface.directory == URL(fileURLWithPath: "/repo"))
    }

    @Test("An absent transcript falls through to a fresh shell")
    func transcriptAbsentFreshShell() throws {
        let planner = makePlanner(transcriptResumable: { _, _ in false })
        let row = makeRow(agentSessionID: "claude-session-3", agentKind: "claudeCode", agentCwd: "/repo")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .freshShell)
    }

    @Test("A moved recorded directory falls back to the resolved root")
    func directoryMovedFallsBackToRoot() throws {
        let planner = makePlanner(
            resolve: { _ in
                ResolvedRestoreTarget(
                    key: .repoPath("/repo"),
                    rootDirectory: URL(fileURLWithPath: "/resolved-root")
                )
            },
            directoryExists: { $0 == "/resolved-root" }
        )
        let row = makeRow(directoryPath: "/moved-away")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .freshShell)
        #expect(surface.directory == URL(fileURLWithPath: "/resolved-root"))
    }

    @Test("A non-Claude agent never picks the resume rung")
    func nonClaudeAgentNeverResumes() throws {
        let planner = makePlanner(transcriptResumable: { _, _ in true })
        let row = makeRow(agentSessionID: "opencode-session", agentKind: "opencode", agentCwd: "/repo")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .freshShell)
    }

    @Test("Surface order is preserved and the selected session comes from the layout snapshot")
    func orderAndSelectionPreserved() throws {
        let first = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
        let planner = makePlanner()
        let layout = TerminalLayoutSnapshotRow(
            id: "snap-1",
            capturedAt: Self.baseDate,
            activeHostSessionID: second,
            selectedSurfaceKind: "repository_terminal",
            selectedSurfaceID: second.uuidString,
            splitPanes: []
        )
        let plan = planner.plan(
            rows: [
                makeRow(hostSessionID: first, directoryPath: "/repo-a"),
                makeRow(hostSessionID: second, directoryPath: "/repo-b"),
            ],
            layout: layout
        )
        #expect(plan.surfaces.map(\.hostSessionID) == [first, second])
        #expect(plan.selectedHostSessionID == second)
    }

    @Test("The prior run's identity threads through to the plan")
    func previousRunIDThreadsThrough() throws {
        let planner = makePlanner()
        let plan = planner.plan(rows: [makeRow()], layout: nil, previousRunID: "run-7")
        #expect(plan.previousRunID == "run-7")
        #expect(planner.plan(rows: [makeRow()], layout: nil).previousRunID == nil)
    }

    @Test("A plan is handled only when its run identity matches the recorded one")
    func wasHandledMatchesRunIdentity() throws {
        let plan = RestorePlan(surfaces: [], selectedHostSessionID: nil, previousRunID: "run-7")
        #expect(plan.wasHandled(handledRunID: "run-7"))
        #expect(!plan.wasHandled(handledRunID: "run-6"))
        #expect(!plan.wasHandled(handledRunID: nil))

        // No run identity (pre-v2 data) → never suppressed: offer rather than
        // silently drop a restorable session set.
        let unidentified = RestorePlan(surfaces: [], selectedHostSessionID: nil, previousRunID: nil)
        #expect(!unidentified.wasHandled(handledRunID: "run-7"))
        #expect(!unidentified.wasHandled(handledRunID: nil))
    }

    @Test("A plan of only seed-key fresh shells offers nothing beyond launch")
    func seedOnlyPlanOffersNothing() throws {
        func surface(
            key: HostTerminalSessionKey, action: RestoreSurfaceAction
        ) -> RestoreSurfacePlan {
            RestoreSurfacePlan(
                hostSessionID: UUID(), key: key,
                directory: URL(fileURLWithPath: "/tmp"), action: action)
        }

        let seedFresh = RestorePlan(
            surfaces: [surface(key: .defaultHome, action: .freshShell)],
            selectedHostSessionID: nil)
        #expect(!seedFresh.offersMoreThanLaunchSeed(seedKey: .defaultHome))

        let seedResume = RestorePlan(
            surfaces: [surface(key: .defaultHome, action: .resumeClaude(agentSessionID: "s1"))],
            selectedHostSessionID: nil)
        #expect(seedResume.offersMoreThanLaunchSeed(seedKey: .defaultHome))

        let withRepo = RestorePlan(
            surfaces: [
                surface(key: .defaultHome, action: .freshShell),
                surface(key: .repoPath("/code/repo"), action: .freshShell),
            ],
            selectedHostSessionID: nil)
        #expect(withRepo.offersMoreThanLaunchSeed(seedKey: .defaultHome))
    }
}
