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
        directoryExists: @escaping TerminalRestorePlanner.DirectoryExistenceCheck = { _ in true },
        newestTranscriptID: @escaping TerminalRestorePlanner.TranscriptIdentityResolver = { _, _ in nil }
    ) -> TerminalRestorePlanner {
        TerminalRestorePlanner(
            resolveTarget: resolve,
            isTmuxSessionAlive: tmuxAlive,
            isTranscriptResumable: transcriptResumable,
            directoryExists: directoryExists,
            newestTranscriptID: newestTranscriptID
        )
    }

    /// A resolver over a fixed newest-first transcript list per directory, skipping
    /// ids an earlier surface already claimed.
    private func transcriptResolver(
        _ byDirectory: [String: [String]]
    ) -> TerminalRestorePlanner.TranscriptIdentityResolver {
        { cwd, claimed in byDirectory[cwd]?.first { !claimed.contains($0) } }
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

    @Test("A row that never recorded an agent session resumes its directory's newest transcript")
    func unrecordedIdentityFallsBackToNewestTranscript() throws {
        // The #889 shape: the surface launched without its hook environment, so no
        // event ever carried an id. The directory still holds the conversation.
        let planner = makePlanner(
            transcriptResumable: { _, _ in true },
            newestTranscriptID: transcriptResolver(["/repo": ["newest", "older"]])
        )
        let plan = planner.plan(rows: [makeRow()], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .resumeClaude(agentSessionID: "newest"))
        #expect(surface.directory == URL(fileURLWithPath: "/repo"))
    }

    @Test("Two rows sharing a directory take different transcripts")
    func sharedDirectoryRowsTakeDistinctTranscripts() throws {
        // Resuming one conversation into two panes would have both agents writing the
        // same transcript, so the second surface takes the next-newest instead.
        let planner = makePlanner(
            transcriptResumable: { _, _ in true },
            newestTranscriptID: transcriptResolver(["/repo": ["newest", "older"]])
        )
        let plan = planner.plan(rows: [makeRow(), makeRow()], layout: nil)
        #expect(plan.surfaces.count == 2)
        #expect(plan.surfaces[0].action == .resumeClaude(agentSessionID: "newest"))
        #expect(plan.surfaces[1].action == .resumeClaude(agentSessionID: "older"))
    }

    @Test("A directory with one transcript and two rows resumes only the first")
    func sharedDirectoryExhaustsTranscripts() throws {
        let planner = makePlanner(
            transcriptResumable: { _, _ in true },
            newestTranscriptID: transcriptResolver(["/repo": ["only"]])
        )
        let plan = planner.plan(rows: [makeRow(), makeRow()], layout: nil)
        #expect(plan.surfaces[0].action == .resumeClaude(agentSessionID: "only"))
        #expect(plan.surfaces[1].action == .freshShell)
    }

    @Test("A recorded id an earlier surface already claimed is not handed out twice")
    func recordedIdentityIsNotReused() throws {
        let shared = "claude-session-shared"
        let planner = makePlanner(
            transcriptResumable: { _, _ in true },
            newestTranscriptID: transcriptResolver(["/repo": [shared]])
        )
        let rows = [
            makeRow(agentSessionID: shared, agentKind: "claudeCode", agentCwd: "/repo"),
            makeRow(agentSessionID: shared, agentKind: "claudeCode", agentCwd: "/repo"),
        ]
        let plan = planner.plan(rows: rows, layout: nil)
        #expect(plan.surfaces[0].action == .resumeClaude(agentSessionID: shared))
        #expect(plan.surfaces[1].action == .freshShell)
    }

    @Test("A non-Claude agent is never handed a Claude transcript")
    func nonClaudeAgentDoesNotTakeTranscriptFallback() throws {
        // The fallback reads ~/.claude transcripts. A directory where Claude once ran
        // must not turn an opencode session into `claude --resume`.
        let planner = makePlanner(
            transcriptResumable: { _, _ in true },
            newestTranscriptID: transcriptResolver(["/repo": ["claude-transcript"]])
        )
        let row = makeRow(agentSessionID: "opencode-session", agentKind: "opencode", agentCwd: "/repo")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .freshShell)
    }

    @Test("A missing directory blocks the transcript fallback")
    func missingDirectoryBlocksFallback() throws {
        let planner = makePlanner(
            transcriptResumable: { _, _ in true },
            directoryExists: { _ in false },
            newestTranscriptID: transcriptResolver(["/repo": ["newest"]])
        )
        let plan = planner.plan(rows: [makeRow()], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .freshShell)
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
        #expect(surface.launchDirectoryFellBack)
    }

    /// The #1233 case: the workspace directory is gone but its tmux session survived.
    /// The plan must still reattach by the recorded name — from the fallback root —
    /// and report the directory switch rather than silently relocating.
    @Test("A reattach with a dead directory keeps the probed name and reports the fallback")
    func reattachWithDeadDirectoryKeepsNameAndReportsFallback() throws {
        let planner = makePlanner(
            resolve: { _ in
                ResolvedRestoreTarget(
                    key: .repoPath("/repo"),
                    rootDirectory: URL(fileURLWithPath: "/resolved-root")
                )
            },
            tmuxAlive: { $0 == "wm-repo-abcd1234" },
            directoryExists: { $0 == "/resolved-root" }
        )
        let row = makeRow(directoryPath: "/moved-away", tmuxSessionName: "wm-repo-abcd1234")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.action == .reattachTmux(sessionName: "wm-repo-abcd1234"))
        #expect(surface.directory == URL(fileURLWithPath: "/resolved-root"))
        #expect(surface.launchDirectoryFellBack)
    }

    @Test("A surviving recorded directory is not reported as a fallback")
    func existingDirectoryIsNotAFallback() throws {
        let planner = makePlanner(tmuxAlive: { _ in true })
        let row = makeRow(tmuxSessionName: "wm-repo-abcd1234")
        let plan = planner.plan(rows: [row], layout: nil)
        let surface = try #require(plan.surfaces.first)
        #expect(surface.directory == URL(fileURLWithPath: "/repo"))
        #expect(!surface.launchDirectoryFellBack)
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

    @Test("A plan of only seed-matching fresh shells offers nothing beyond launch")
    func seedOnlyPlanOffersNothing() throws {
        let seedDirectory = URL(fileURLWithPath: "/tmp")
        func surface(
            key: HostTerminalSessionKey, action: RestoreSurfaceAction,
            directory: URL = URL(fileURLWithPath: "/tmp")
        ) -> RestoreSurfacePlan {
            RestoreSurfacePlan(
                hostSessionID: UUID(), key: key,
                directory: directory, action: action)
        }

        let seedFresh = RestorePlan(
            surfaces: [surface(key: .defaultHome, action: .freshShell)],
            selectedHostSessionID: nil)
        #expect(!seedFresh.offersMoreThanLaunchSeed(seedKey: .defaultHome, seedDirectory: seedDirectory))

        let seedResume = RestorePlan(
            surfaces: [surface(key: .defaultHome, action: .resumeClaude(agentSessionID: "s1"))],
            selectedHostSessionID: nil)
        #expect(seedResume.offersMoreThanLaunchSeed(seedKey: .defaultHome, seedDirectory: seedDirectory))

        let withRepo = RestorePlan(
            surfaces: [
                surface(key: .defaultHome, action: .freshShell),
                surface(key: .repoPath("/code/repo"), action: .freshShell),
            ],
            selectedHostSessionID: nil)
        #expect(withRepo.offersMoreThanLaunchSeed(seedKey: .defaultHome, seedDirectory: seedDirectory))

        // A seed-key fresh shell at a DIFFERENT directory is a real restore, not a
        // seed duplicate (the default host directory can change between runs).
        let differentDirectory = RestorePlan(
            surfaces: [
                surface(
                    key: .defaultHome, action: .freshShell,
                    directory: URL(fileURLWithPath: "/somewhere/else"))
            ],
            selectedHostSessionID: nil)
        #expect(
            differentDirectory.offersMoreThanLaunchSeed(
                seedKey: .defaultHome, seedDirectory: seedDirectory))
    }
}
