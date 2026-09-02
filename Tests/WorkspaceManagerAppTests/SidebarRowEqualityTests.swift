import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// The contract behind #1366: a row's display state is a complete account of what that row and
/// its hover card draw, and it is scoped to that row's own session. Together those two make the
/// `Equatable` skip safe — the first means nothing on screen can change without the state
/// changing, the second means one session's event moves one row's state.
@MainActor
@Suite("Sidebar row equality")
struct SidebarRowEqualityTests {
    private let controller = SidebarWorkspacePresentationController()

    private func session(
        at path: String,
        key: HostTerminalSessionKey? = nil
    ) -> HostTerminalSession {
        let directory = URL(fileURLWithPath: path)
        return HostTerminalSession(
            key: key ?? .hostPath(path),
            directory: directory
        )
    }

    private func status(
        for session: HostTerminalSession,
        run: AgentRunState = .thinking,
        lastEventAt: Date = Date(timeIntervalSince1970: 1_000),
        costUSD: Double? = nil
    ) -> AgentSessionStatus {
        AgentSessionStatus(
            hostSessionID: session.id,
            kind: .claudeCode,
            cwd: session.directoryPath,
            run: run,
            costUSD: costUSD,
            lastEventAt: lastEventAt,
            hookActive: true
        )
    }

    // MARK: - Scoping

    @Test("A row's session state carries only the tabs sharing its key")
    func rowSessionStateIsScopedToItsKey() {
        let mine = session(at: "/repos/alpha")
        let theirs = session(at: "/repos/beta")
        let statuses = [mine.id: status(for: mine), theirs.id: status(for: theirs)]

        let state = controller.rowSessionState(
            for: .hostPath("/repos/alpha"),
            sessions: [mine, theirs],
            agentStatus: { statuses[$0] }
        )

        #expect(state.sessions.map(\.id) == [mine.id])
        #expect(state.statuses.count == 1)
        #expect(state.statuses[0]?.hostSessionID == mine.id)
    }

    @Test("An event on one session leaves every other row's state untouched")
    func oneSessionsEventMovesOneRowsState() {
        let alpha = session(at: "/repos/alpha")
        let beta = session(at: "/repos/beta")
        var statuses = [alpha.id: status(for: alpha), beta.id: status(for: beta)]

        func state(for path: String) -> SidebarRowSessionState {
            controller.rowSessionState(
                for: .hostPath(path),
                sessions: [alpha, beta],
                agentStatus: { statuses[$0] }
            )
        }

        let alphaBefore = state(for: "/repos/alpha")
        let betaBefore = state(for: "/repos/beta")

        statuses[alpha.id] = status(
            for: alpha, run: .awaitingInput(reason: .permissionPrompt),
            lastEventAt: Date(timeIntervalSince1970: 2_000))

        #expect(state(for: "/repos/alpha") != alphaBefore)
        #expect(state(for: "/repos/beta") == betaBefore)
    }

    @Test("An unregistered session leaves the row's state empty rather than absent")
    func rowWithoutSessionsHasEmptyState() {
        let state = controller.rowSessionState(
            for: .hostPath("/repos/alpha"),
            sessions: [],
            agentStatus: { _ in nil }
        )

        #expect(state == SidebarRowSessionState())
        #expect(state.freshestStatus == nil)
        #expect(!state.hasAnyStatus)
    }

    // MARK: - Completeness of the fingerprint

    /// Every field the hover card reads has to move the row's state, because a card that is
    /// already open is rebuilt only when its row's body runs again. These are the four the card
    /// reads that the row itself does not draw.
    @Test("Agent detail the row never draws still moves the row's state")
    func agentDetailMovesTheState() {
        let tab = session(at: "/repos/alpha")
        var statuses = [tab.id: status(for: tab, costUSD: 0.10)]

        func state() -> SidebarRowSessionState {
            controller.rowSessionState(
                for: .hostPath("/repos/alpha"), sessions: [tab], agentStatus: { statuses[$0] })
        }

        let before = state()
        // Cost shows on the card and nowhere on the row: the activity dot, the pane badge and
        // the live line are all unchanged by it.
        statuses[tab.id] = status(for: tab, costUSD: 0.20)

        #expect(state() != before)
    }

    @Test("A tab opening or closing on the row's key moves the row's state")
    func tabSetMovesTheState() {
        let first = session(at: "/repos/alpha")
        let second = session(at: "/repos/alpha")

        let oneTab = controller.rowSessionState(
            for: .hostPath("/repos/alpha"), sessions: [first], agentStatus: { _ in nil })
        let twoTabs = controller.rowSessionState(
            for: .hostPath("/repos/alpha"), sessions: [first, second], agentStatus: { _ in nil })

        #expect(oneTab != twoTabs)
    }

    /// The two lazy resolutions land *after* a hover card opens, so if they did not ride the
    /// row's state the card that triggered them would never show them.
    @Test("A foreground name or transcript tail resolving moves the row's state")
    func lazyResolutionsMoveTheState() {
        let plain = session(at: "/repos/alpha")
        let agent = session(at: "/repos/alpha")
        let statuses = [agent.id: status(for: agent)]
        var names: [UUID: String] = [:]
        var tails: [UUID: String] = [:]

        func state() -> SidebarRowSessionState {
            controller.rowSessionState(
                for: .hostPath("/repos/alpha"),
                sessions: [plain, agent],
                agentStatus: { statuses[$0] },
                foregroundName: { names[$0] },
                transcriptTail: { tails[$0] }
            )
        }

        let unresolved = state()

        names[plain.id] = "nvim"
        let withName = state()
        #expect(withName != unresolved)

        tails[agent.id] = "Ran the suite; 1973 passed."
        #expect(state() != withName)
    }

    // MARK: - Derivations the row reads off the gathered state

    @Test("The freshest status is the latest event among the row's tabs")
    func freshestStatusPicksTheLatestEvent() {
        let older = session(at: "/repos/alpha")
        let newer = session(at: "/repos/alpha")
        let statuses = [
            older.id: status(for: older, lastEventAt: Date(timeIntervalSince1970: 100)),
            newer.id: status(
                for: newer, run: .errored(category: .toolFailure, message: "boom"),
                lastEventAt: Date(timeIntervalSince1970: 200)),
        ]

        let state = controller.rowSessionState(
            for: .hostPath("/repos/alpha"),
            sessions: [older, newer],
            agentStatus: { statuses[$0] }
        )

        #expect(state.freshestStatus?.hostSessionID == newer.id)
        #expect(controller.liveSessionStatus(from: state)?.kind == .claudeCode)
    }

    @Test("Activity resolved from gathered state matches the direct lookup")
    func activityMatchesTheDirectLookup() {
        let key = HostTerminalSessionKey.hostPath("/repos/alpha")
        let tab = session(at: "/repos/alpha")
        let statuses = [tab.id: status(for: tab, run: .awaitingInput(reason: .permissionPrompt))]
        let lookup: (UUID) -> AgentSessionStatus? = { statuses[$0] }

        let direct = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 1],
            activeSessionKey: nil,
            sessions: [tab],
            agentStatus: lookup
        )
        let viaState = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 1],
            activeSessionKey: nil,
            sessionState: controller.rowSessionState(
                for: key, sessions: [tab], agentStatus: lookup)
        )

        #expect(direct == viaState)
        #expect(direct == .awaitingInput)
    }

    // MARK: - Pin moves read off the row's state

    /// The Move Up / Move Down entries used to rebuild the Pinned ordering from a workspace list
    /// the menu closure had captured. Reading the position off the row's state both retires that
    /// sort and makes the answer part of what the row compares on.
    @Test("Pin-move availability read off the row's state matches the controller")
    func pinMoveAvailabilityMatchesTheController() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/repos/alpha"))
        let workspaces = (0..<3).map { index in
            let workspace = Workspace(
                name: "ws-\(index)",
                path: URL(fileURLWithPath: "/repos/alpha/ws-\(index)"),
                sourceRepo: repo
            )
            workspace.pinOrder = index
            return workspace
        }
        let unpinned = Workspace(
            name: "loose", path: URL(fileURLWithPath: "/repos/alpha/loose"), sourceRepo: repo)
        let all = workspaces + [unpinned]

        let pinController = SidebarPinController()
        let pinned = pinController.pinnedWorkspaces(in: all)

        for workspace in all {
            let state = Self.pinState(
                for: workspace,
                pinnedIndex: pinned.firstIndex { $0.id == workspace.id },
                pinnedCount: pinned.count
            )
            #expect(state.canMovePinUp == pinController.canMove(workspace, by: -1, in: all))
            #expect(state.canMovePinDown == pinController.canMove(workspace, by: 1, in: all))
        }
    }

    // MARK: - Object identity

    /// Raised in review of #1504: `MainWindowOrderSignature` defends against SwiftData handing
    /// back a replacement instance with identical values, but a row keyed on `id` plus drawn
    /// values alone would compare equal across that swap — skipping its body and keeping closures
    /// over the superseded object, which `setNote`, `togglePin`, `deleteWorkspace` and
    /// `workspace.path` all dereference directly. The row-side mirror of
    /// `MainWindowOrderCacheTests.objectIdentityInvalidates`.
    @Test("A replacement instance with identical values still moves the row's state")
    func replacementInstanceMovesTheRowState() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/repos/alpha"))
        let original = Workspace(
            name: "ws", path: URL(fileURLWithPath: "/repos/alpha/ws"), sourceRepo: repo)

        let replacement = Workspace(
            name: original.name,
            path: URL(fileURLWithPath: original.path),
            sourceRepo: repo,
            lastAccessedAt: original.lastAccessedAt
        )
        replacement.id = original.id
        replacement.createdAt = original.createdAt

        let before = Self.pinState(for: original, pinnedIndex: nil, pinnedCount: 0)
        let after = Self.pinState(for: replacement, pinnedIndex: nil, pinnedCount: 0)

        #expect(before.workspaceID == after.workspaceID, "the same workspace by id")
        #expect(before.name == after.name, "and by every value the row draws")
        #expect(before != after, "yet the row must rebuild so its closures drop the old object")
    }

    /// The converse, and the reason the fingerprint is safe to add: the same instance must not
    /// manufacture a difference, or every row would rebuild on every evaluation and undo the
    /// slice this PR is about.
    @Test("The same instance compares equal, so identity costs no extra rebuilds")
    func sameInstanceStillComparesEqual() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/repos/alpha"))
        let workspace = Workspace(
            name: "ws", path: URL(fileURLWithPath: "/repos/alpha/ws"), sourceRepo: repo)

        #expect(
            Self.pinState(for: workspace, pinnedIndex: nil, pinnedCount: 0)
                == Self.pinState(for: workspace, pinnedIndex: nil, pinnedCount: 0)
        )
    }

    private static func pinState(
        for workspace: Workspace,
        pinnedIndex: Int?,
        pinnedCount: Int,
        pinGraphRevision: Int = 0
    ) -> WorkspaceRowDisplayState {
        WorkspaceRowDisplayState(
            workspaceID: workspace.id,
            identity: ObjectIdentifier(workspace),
            name: workspace.name,
            status: workspace.status,
            backendIdentifier: workspace.backendIdentifier,
            gitBranch: workspace.gitBranch,
            note: workspace.note,
            createdAt: workspace.createdAt,
            repoRemoteURL: nil,
            isSelected: false,
            statusMessage: nil,
            sessionActivity: .inactive,
            paneCount: 0,
            repoContext: nil,
            isNested: true,
            isExpanded: false,
            showsDisclosure: false,
            isPinned: workspace.isPinned,
            isPinnable: true,
            isPinnedSectionRow: pinnedIndex != nil,
            pinnedIndex: pinnedIndex,
            pinnedCount: pinnedCount,
            pinGraphRevision: pinGraphRevision,
            liveStatus: nil,
            sessionState: SidebarRowSessionState()
        )
    }
}
