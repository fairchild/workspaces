//
//  MainWindowOpenSurfaceReattachControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for which of the previous run's scopes a launch rejoins (#1374): what makes a
//  restored session record worth realizing, what makes it a scope's stand-in, what the tmux
//  liveness answer does to the set, and which of the survivors the pass actually attaches
//  rather than finds already attached (#1398).
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowOpenSurfaceReattach")
struct MainWindowOpenSurfaceReattachControllerTests {
    private let controller = MainWindowOpenSurfaceReattachController()

    // MARK: - Fixtures

    /// Directories the candidate filter stats, created for real: the "still on disk" rule is
    /// the one thing here that cannot be answered from the session value alone.
    private final class TemporaryDirectories {
        let root: URL

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("reattach-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func make(_ name: String) -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func session(
        directory: URL,
        key: HostTerminalSessionKey? = nil,
        customCommand: String? = nil,
        initialCommand: String? = nil
    ) -> HostTerminalSession {
        HostTerminalSession(
            key: key ?? .hostPath(directory.path),
            directory: directory,
            customCommand: customCommand,
            initialCommand: initialCommand
        )
    }

    private func candidates(
        _ sessions: [HostTerminalSession],
        activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID] = [:],
        excludedSessionIDs: Set<UUID> = [],
        excludedScopeKeys: Set<HostTerminalSessionKey> = [],
        terminalMode: TerminalMultiplexingMode = .tmuxPerSession,
        limit: Int = MainWindowOpenSurfaceReattachController.maximumSurfaces
    ) -> [MainWindowOpenSurfaceReattachController.Candidate] {
        controller.candidates(
            sessions: sessions,
            activeSessionIDByScopeKey: activeSessionIDByScopeKey,
            excludedSessionIDs: excludedSessionIDs,
            excludedScopeKeys: excludedScopeKeys,
            terminalMode: terminalMode,
            limit: limit
        )
    }

    // MARK: - What a launch offers to rejoin

    /// The point of the pass: a workspace whose session record came back but whose surface was
    /// never realized is exactly the one a relaunch appeared to lose.
    @Test("A restored workspace scope is offered for rejoining")
    func restoredWorkspaceScopeIsOffered() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let workspace = session(directory: directories.make("alpha"))

        let result = candidates([workspace])

        #expect(result.map(\.sessionID) == [workspace.id])
        #expect(result.first?.tmuxSessionName == workspace.effectiveTmuxSessionName)
    }

    /// Without tmux a surface's shell died with the previous process, so realizing its record
    /// would start a fresh shell rather than rejoin anything the user left running.
    @Test("Ghostty-managed mode offers nothing to rejoin")
    func ghosttyManagedModeOffersNothing() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }

        let result = candidates(
            [session(directory: directories.make("alpha"))],
            terminalMode: .ghosttyManagedSplits
        )

        #expect(result.isEmpty)
    }

    /// The window realizes the scope it lands on; rejoining it again would be redundant work
    /// on the launch path.
    @Test("An already-realized session is not offered again")
    func alreadyRealizedSessionIsSkipped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let alpha = session(directory: directories.make("alpha"))
        let beta = session(directory: directories.make("beta"))

        let result = candidates([alpha, beta], excludedSessionIDs: [alpha.id])

        #expect(result.map(\.sessionID) == [beta.id])
    }

    /// A scope the user archived should not come back on launch — the same rule the continuity
    /// writes already apply.
    @Test("An archived scope is not offered")
    func archivedScopeIsSkipped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let alpha = session(directory: directories.make("alpha"))
        let beta = session(directory: directories.make("beta"))

        let result = candidates([alpha, beta], excludedScopeKeys: [alpha.key])

        #expect(result.map(\.sessionID) == [beta.id])
    }

    /// A scope shows one terminal at a time, so its recorded active session is the one the user
    /// left in front of them; its sibling tabs realize when they are switched to.
    @Test("Only a scope's active session stands in for the scope")
    func onlyTheScopeActiveSessionIsOffered() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let directory = directories.make("alpha")
        let firstTab = session(directory: directory)
        let secondTab = session(directory: directory)

        let result = candidates(
            [firstTab, secondTab],
            activeSessionIDByScopeKey: [firstTab.key: secondTab.id]
        )

        #expect(result.map(\.sessionID) == [secondTab.id])
    }

    /// Reaching the scope's active session settles the scope: when that session is already
    /// realized, a sibling tab is not a stand-in for it.
    @Test("An excluded active session leaves its scope with no stand-in")
    func excludedActiveSessionLeavesScopeEmpty() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let directory = directories.make("alpha")
        let firstTab = session(directory: directory)
        let secondTab = session(directory: directory)

        let result = candidates(
            [firstTab, secondTab],
            activeSessionIDByScopeKey: [firstTab.key: secondTab.id],
            excludedSessionIDs: [secondTab.id]
        )

        #expect(result.isEmpty)
    }

    /// A remote session's command is an SSH invocation; re-running it on launch is a
    /// connection the user did not ask for.
    @Test("A remote session is not offered")
    func remoteSessionIsSkipped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let remote = session(directory: directories.make("alpha"), customCommand: "ssh box")

        #expect(candidates([remote]).isEmpty)
    }

    /// An initial command runs an agent. Restore chooses that deliberately; a rejoin pass
    /// must not repeat it behind the user's back.
    @Test("A session carrying an initial command is not offered")
    func initialCommandSessionIsSkipped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let resuming = session(
            directory: directories.make("alpha"),
            initialCommand: "claude --resume abc"
        )

        #expect(candidates([resuming]).isEmpty)
    }

    /// A provider-backed scope reconnects through its provider, which has setup steps and
    /// costs of its own.
    @Test("A provider-backed scope is not offered")
    func backendScopeIsSkipped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let backed = session(
            directory: directories.make("alpha"),
            key: .backendSession(providerID: "lume", instanceID: "vm-1")
        )

        #expect(candidates([backed]).isEmpty)
    }

    /// A workspace whose directory was deleted between runs has nowhere to launch.
    @Test("A scope whose directory is gone is not offered")
    func missingDirectoryScopeIsSkipped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let alpha = session(directory: directories.make("alpha"))
        let gone = session(directory: directories.root.appendingPathComponent("gone", isDirectory: true))

        let result = candidates([alpha, gone])

        #expect(result.map(\.sessionID) == [alpha.id])
    }

    /// Each rejoin starts a shell and attaches a tmux client, so a long history of scopes
    /// cannot turn one launch into dozens of process starts.
    @Test("The offered set is capped")
    func offeredSetIsCapped() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let sessions = (0..<5).map { session(directory: directories.make("scope-\($0)")) }

        let result = candidates(sessions, limit: 3)

        #expect(result.map(\.sessionID) == sessions.prefix(3).map(\.id))
    }

    // MARK: - Liveness

    /// Liveness is the safety argument: a surviving session is what the user means by "my
    /// workspaces are still open", and a scope without one still opens on demand.
    @Test("Only scopes with a surviving tmux session are rejoined")
    func onlyLiveScopesAreRejoined() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let alive = session(directory: directories.make("alpha"))
        let dead = session(directory: directories.make("beta"))
        let offered = candidates([alive, dead])

        let rejoined = controller.reattachableSessionIDs(
            candidates: offered,
            liveTmuxSessionNames: [alive.effectiveTmuxSessionName]
        )

        #expect(rejoined == [alive.id])
    }

    @Test("No surviving session means nothing is rejoined")
    func noLiveSessionsRejoinsNothing() {
        let directories = TemporaryDirectories()
        defer { directories.remove() }
        let offered = candidates([session(directory: directories.make("alpha"))])

        #expect(controller.reattachableSessionIDs(candidates: offered, liveTmuxSessionNames: []).isEmpty)
    }

    // MARK: - What the pass actually attached

    /// The reason the split exists: a restore plan realizes the scopes it covers, so a scope
    /// can already be a live surface before the pass reaches it. Realizing it again attaches
    /// nothing, and reporting it as rejoined told an operator the pass had worked when it had
    /// not (#1398).
    @Test("A scope realized before the pass ran counts as already live, not rejoined")
    func alreadyLiveScopeIsNotCountedAsRejoined() {
        let restored = UUID()
        let dark = UUID()

        let split = controller.split(
            reattachableSessionIDs: [restored, dark],
            isSurfaceRealized: { $0 == restored }
        )

        #expect(split.toRealize == [dark])
        #expect(split.alreadyLive == [restored])
    }

    /// The launch the pass exists for: nothing was attached before it, so everything it
    /// realizes is work it did.
    @Test("Scopes with no surface are all the pass's to realize")
    func darkScopesAreAllToRealize() {
        let ids = [UUID(), UUID()]

        let split = controller.split(reattachableSessionIDs: ids, isSurfaceRealized: { _ in false })

        #expect(split.toRealize == ids)
        #expect(split.alreadyLive.isEmpty)
    }

    /// The launch from the report: the restore plan covered the whole open set, so the pass had
    /// nothing left to attach and must say so rather than claim two rejoins.
    @Test("A fully restored open set leaves the pass nothing to rejoin")
    func fullyRestoredOpenSetRejoinsNothing() {
        let ids = [UUID(), UUID()]

        let split = controller.split(reattachableSessionIDs: ids, isSurfaceRealized: { _ in true })

        #expect(split.toRealize.isEmpty)
        #expect(split.alreadyLive == ids)
    }

    /// Both sides keep candidate order, so the counts in a log line can be read back against
    /// the order the manifest replayed.
    @Test("The split preserves candidate order on both sides")
    func splitPreservesCandidateOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        let split = controller.split(
            reattachableSessionIDs: [first, second, third, fourth],
            isSurfaceRealized: { $0 == second || $0 == third }
        )

        #expect(split.toRealize == [first, fourth])
        #expect(split.alreadyLive == [second, third])
    }

    // MARK: - Policy

    @Test("Rejoining is on by default")
    func rejoiningIsOnByDefault() {
        #expect(MainWindowOpenSurfaceReattachPolicy.isEnabled(environment: [:]))
    }

    /// A runner has no prior desktop session to rejoin, and a dozen extra shells there is only
    /// noise in a lane that measures the window.
    @Test("CI does not rejoin")
    func ciDoesNotRejoin() {
        #expect(!MainWindowOpenSurfaceReattachPolicy.isEnabled(environment: ["CI": "true"]))
    }

    @Test("The opt-out environment variable disables rejoining")
    func optOutDisablesRejoining() {
        #expect(
            !MainWindowOpenSurfaceReattachPolicy.isEnabled(
                environment: [MainWindowOpenSurfaceReattachPolicy.disableEnvironmentKey: "1"]
            )
        )
    }

    /// An unset-looking value is not an opt-out; only an affirmative one turns the pass off.
    @Test("A non-affirmative opt-out value leaves rejoining on")
    func nonAffirmativeOptOutLeavesRejoiningOn() {
        #expect(
            MainWindowOpenSurfaceReattachPolicy.isEnabled(
                environment: [MainWindowOpenSurfaceReattachPolicy.disableEnvironmentKey: "0"]
            )
        )
    }
}

@MainActor
@Suite("MainWindowLaunchWorkLifetime")
struct MainWindowLaunchWorkLifetimeTests {
    /// The launch task is unstructured, so a closing window neither cancels nor completes the
    /// rejoin pass; the flag is the only thing that tells it to stop (#1374).
    @Test("Teardown marks the window down, reappearing clears it")
    func lifetimeTracksTeardownAndReappearance() {
        let lifetime = MainWindowLaunchWorkLifetime()

        #expect(!lifetime.isWindowTornDown)

        lifetime.noteWindowTornDown()
        #expect(lifetime.isWindowTornDown)

        lifetime.noteWindowAppeared()
        #expect(!lifetime.isWindowTornDown)
    }
}

/// The launch-pass claim is process-wide state, so its suite runs alone and hands the claim
/// back after each case.
@MainActor
@Suite("MainWindowOpenSurfaceReattachLaunchPass", .serialized)
struct MainWindowOpenSurfaceReattachLaunchPassTests {
    /// Every window restores the same manifest into its own store, so a second window claiming
    /// the pass would start a second shell per scope and attach a second client to every
    /// surviving tmux session.
    @Test("Only the first window claims the launch pass")
    func onlyFirstWindowClaimsLaunchPass() {
        MainWindowOpenSurfaceReattachPolicy.releaseLaunchPassForTesting()
        defer { MainWindowOpenSurfaceReattachPolicy.releaseLaunchPassForTesting() }

        #expect(MainWindowOpenSurfaceReattachPolicy.claimLaunchPass())
        #expect(!MainWindowOpenSurfaceReattachPolicy.claimLaunchPass())
        #expect(!MainWindowOpenSurfaceReattachPolicy.claimLaunchPass())
    }
}
