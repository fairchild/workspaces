//
//  TmuxSessionOwnershipTests.swift
//  WorkspaceManagerTests
//
//  Binds the attribution rule #1267 turns on: a tmux session may be killed only when
//  the app recorded creating (or binding to) that specific session id, and only while
//  that id still holds the name it was recorded under. Names prove nothing here.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TmuxSessionOwnership")
struct TmuxSessionOwnershipTests {

    // MARK: - Session id shape

    @Test("A tmux session id is a dollar sign and digits, and nothing else passes")
    func sessionIDShape() {
        #expect(TmuxLiveSession.isWellFormedSessionID("$0"))
        #expect(TmuxLiveSession.isWellFormedSessionID("$412"))
        // The one that matters: tmux reads a missing or empty `-t` as the *current*
        // session and kills it, exiting 0. An optional that collapsed to "" must never
        // reach `kill-session`.
        #expect(TmuxLiveSession.isWellFormedSessionID("") == false)
        #expect(TmuxLiveSession.isWellFormedSessionID("$") == false)
        #expect(TmuxLiveSession.isWellFormedSessionID("wm-repo-abcd1234") == false)
        #expect(TmuxLiveSession.isWellFormedSessionID("=wm-repo-abcd1234") == false)
        #expect(TmuxLiveSession.isWellFormedSessionID("$3x") == false)
    }

    // MARK: - Reading the socket

    @Test("list-sessions rows parse into identities, malformed rows are skipped")
    func parsesLiveSessions() throws {
        let output = """
            $0\twm-repo-abcd1234\t1788328043\t35533
            $1\tprobe-bystander\t1788327000\t35533
            garbage-without-fields
            $2\t\t1788328100\t35533
            notanid\tsomething\t1788328100\t35533
            $3\tno-created-time\tnot-a-number\t35533
            """
        let sessions = try #require(TmuxSessionProbe.parseLiveSessions(fromListSessions: output))

        #expect(sessions.count == 2)
        #expect(sessions[0].sessionID == "$0")
        #expect(sessions[0].name == "wm-repo-abcd1234")
        #expect(sessions[0].createdAt == Date(timeIntervalSince1970: 1_788_328_043))
        #expect(sessions[0].serverPID == 35533)
        #expect(sessions[1].name == "probe-bystander")
    }

    @Test("An unanswered list-sessions is unknown, not an empty socket")
    func unansweredListIsNil() {
        // A socket that cannot be read must not read as "there is nothing there", which
        // is the shape that would authorize acting on absence.
        #expect(TmuxSessionProbe.parseLiveSessions(fromListSessions: nil) == nil)
        #expect(TmuxSessionProbe.parseLiveSessions(fromListSessions: "")?.isEmpty == true)
    }

    @Test("liveSessions asks tmux for id, name, created time and server pid")
    func liveSessionsCommandShape() async throws {
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            runForOutput: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return "$0\twm-repo-abcd1234\t1788328043\t35533\n"
            },
            environment: [:]
        )
        _ = await probe.liveSessions()

        let call = try #require(await recorder.calls.first)
        #expect(call.arguments.contains("list-sessions"))
        #expect(call.arguments.contains("#{session_id}\t#{session_name}\t#{session_created}\t#{pid}"))
    }

    // MARK: - Killing by id

    @Test("killSession(id:) targets the bare session id, not an exact-name match")
    func killByIDCommandShape() async throws {
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            environment: [:]
        )
        #expect(await probe.killSession(id: "$7"))

        let call = try #require(await recorder.calls.first)
        #expect(call.arguments.contains("kill-session"))
        // `=$7` would be an exact match on a session literally named "$7".
        #expect(adjacent(call.arguments, "-t", "$7"))
    }

    @Test("A malformed session id never reaches tmux")
    func malformedIDIsRefusedBeforeLaunch() async {
        // Verified against a real tmux on an isolated socket: `kill-session -t ''`
        // kills the current session and exits 0. So the guard has to sit before the
        // process launch, not be inferred from an exit code afterwards.
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            environment: [:]
        )
        #expect(await probe.killSession(id: "") == false)
        #expect(await probe.killSession(id: "wm-repo-abcd1234") == false)
        #expect(await recorder.calls.isEmpty)
    }

    // MARK: - Socket resolution

    @Test("An isolated run names its own socket; an empty override reads as unset")
    func socketLabelResolution() {
        #expect(TmuxSessionProbe.resolvedSocketLabel(from: [:]) == "workspaces")
        #expect(
            TmuxSessionProbe.resolvedSocketLabel(from: ["WORKSPACES_TMUX_SOCKET_LABEL": "wave3test"])
                == "wave3test")
        #expect(
            TmuxSessionProbe.resolvedSocketLabel(from: ["WORKSPACES_TMUX_SOCKET_LABEL": "  "])
                == "workspaces")
        // The CLI's entry point and the app's now answer from one resolution, so a
        // launch and the probe that inspects it can never land on different servers.
        #expect(
            TmuxSessionControl.socketLabel(from: ["WORKSPACES_TMUX_SOCKET_LABEL": "wave3test"])
                == "wave3test")
    }

    @Test("An unset or blank override still means the app's own socket")
    func absentOverrideMeansTheDefaultSocket() {
        #expect(TmuxSessionProbe.resolvedSocketLabel(from: [:]) == "workspaces")
        #expect(
            TmuxSessionProbe.resolvedSocketLabel(from: ["WORKSPACES_TMUX_SOCKET_LABEL": "  "])
                == "workspaces")
        #expect(TmuxSessionProbe.quarantineSocketLabel != TmuxSessionProbe.defaultSocketLabel)
        #expect(TmuxSessionProbe.isSafeSocketLabel(TmuxSessionProbe.quarantineSocketLabel))
    }

    @Test("A socket label that would become shell text is refused, not reproduced")
    func unsafeSocketLabelsFallBackToTheDefault() {
        // The label is interpolated into the shell script a terminal execs, so making
        // it configurable is what put a caller-chosen value on that path.
        for hostile in [
            "wave3test; rm -rf /", "a b", "$(id)", "`id`", "a|b", "a\nb", "../escape",
            "a'b", "a\"b", "a&b", String(repeating: "x", count: 65),
        ] {
            // Quarantined, never the shared socket. An operator who asked for an
            // isolated run and mistyped the label must not be handed the socket
            // carrying the desktop's live sessions.
            #expect(
                TmuxSessionProbe.resolvedSocketLabel(
                    from: ["WORKSPACES_TMUX_SOCKET_LABEL": hostile])
                    == TmuxSessionProbe.quarantineSocketLabel,
                "expected the quarantine socket for \(hostile)")
        }
        for ordinary in ["wave3test", "wm-dev", "wm_dev", "socket.2", "A1"] {
            #expect(
                TmuxSessionProbe.resolvedSocketLabel(
                    from: ["WORKSPACES_TMUX_SOCKET_LABEL": ordinary]) == ordinary)
        }
    }

    // MARK: - Provenance

    @MainActor
    @Test("A session older than the launch was adopted; one at or after it was created")
    func provenanceFromCreationTime() {
        let ledger = TmuxSessionOwnershipLedger()
        let launchedAt = Date(timeIntervalSince1970: 1_788_328_040.4)

        let bystander = ledger.record(
            hostSessionID: UUID(),
            identity: live("$0", "wm-repo-abcd1234", 1_788_320_000),
            launchedAt: launchedAt
        )
        #expect(bystander.provenance == .adopted)

        let seeded = ledger.record(
            hostSessionID: UUID(),
            identity: live("$1", "wm-repo-abcd1234", 1_788_328_041),
            launchedAt: launchedAt
        )
        #expect(seeded.provenance == .createdByThisLaunch)
    }

    @MainActor
    @Test("A session created in the same second as the launch counts as this launch's")
    func provenanceFloorsToTheSecond() {
        // tmux reports `session_created` in whole seconds while the launch instant has
        // sub-second precision, so the comparison floors the launch. Without that, a
        // session this launch created 300ms after the stamp reads as older than it.
        let ledger = TmuxSessionOwnershipLedger()
        let ownership = ledger.record(
            hostSessionID: UUID(),
            identity: live("$1", "wm-repo-abcd1234", 1_788_328_040),
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040.7)
        )
        #expect(ownership.provenance == .createdByThisLaunch)
    }

    // MARK: - Authorization

    @MainActor
    @Test("A session the app cannot attribute to itself is never a kill target")
    func unattributableSessionIsNeverAKillTarget() {
        // The reported #1267 scenario, at the seam: a hand-created session holds the
        // socket, and the app knows nothing about it. No amount of name agreement
        // makes it killable.
        let ledger = TmuxSessionOwnershipLedger()
        let unknownSurface = UUID()
        let bystander = live("$0", "probe-bystander", 1_788_320_000)

        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: unknownSurface,
                liveSessions: [bystander],
                requiringCreation: false
            ) == nil
        )
    }

    @MainActor
    @Test("An adopted session is refused at launch time and allowed at teardown")
    func adoptionIsRefusedByTheLaunchTimePass() {
        // The hole #1291 left open. A seed launched with `new-session -A` on a name a
        // foreign session already holds *attaches* to it, so the name enters the set of
        // names this launch is holding and the old name-based check re-authorizes the
        // kill. Creation provenance is what separates the two, and only the launch-time
        // pass demands it: an explicit teardown of the surface bound to that session is
        // a person asking for it.
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        let foreign = live("$0", "wm-repo-abcd1234", 1_788_320_000)
        ledger.record(
            hostSessionID: surface,
            identity: foreign,
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040)
        )

        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface, liveSessions: [foreign], requiringCreation: true) == nil
        )
        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface, liveSessions: [foreign], requiringCreation: false) == "$0"
        )
    }

    @MainActor
    @Test("A session this launch created is authorized, by id")
    func createdSessionIsAuthorized() {
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        let seed = live("$4", "wm-repo-abcd1234", 1_788_328_041)
        ledger.record(
            hostSessionID: surface, identity: seed,
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040))

        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface, liveSessions: [seed], requiringCreation: true) == "$4"
        )
    }

    @MainActor
    @Test("An id that has left the socket, or changed name, authorizes nothing")
    func staleRecordsAuthorizeNothing() {
        // Freshness. The record is a claim about the past; between it and the kill a
        // session can exit or be renamed, and a different one can take its name.
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        ledger.record(
            hostSessionID: surface,
            identity: live("$4", "wm-repo-abcd1234", 1_788_328_041),
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040)
        )

        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface, liveSessions: [], requiringCreation: true) == nil
        )
        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface,
                liveSessions: [live("$4", "renamed-by-someone", 1_788_328_041)],
                requiringCreation: true
            ) == nil
        )
        // A different session that has taken the recorded *name* is not the recorded session.
        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface,
                liveSessions: [live("$9", "wm-repo-abcd1234", 1_788_329_000)],
                requiringCreation: true
            ) == nil
        )
    }

    @MainActor
    @Test("An id reissued by a restarted tmux server authorizes nothing")
    func reissuedIDFromAnotherServerLifetimeAuthorizesNothing() {
        // Session ids are unique for a *server's* lifetime, so a restarted server issues
        // `$0` again — and the names here are directory derivations, so the app opening
        // the same directory again produces the same name. Id and name together can be
        // reissued to an unrelated session; creation time and server pid cannot.
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        ledger.record(
            hostSessionID: surface,
            identity: TmuxLiveSession(
                sessionID: "$0", name: "wm-repo-abcd1234",
                createdAt: Date(timeIntervalSince1970: 1_788_328_041), serverPID: 35533),
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040)
        )

        let afterRestart = TmuxLiveSession(
            sessionID: "$0", name: "wm-repo-abcd1234",
            createdAt: Date(timeIntervalSince1970: 1_788_400_000), serverPID: 90210)

        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface, liveSessions: [afterRestart], requiringCreation: true)
                == nil
        )
        #expect(
            ledger.authorizedKillTarget(
                forHostSessionID: surface, liveSessions: [afterRestart], requiringCreation: false)
                == nil
        )
    }

    // MARK: - Terminator

    @MainActor
    @Test("The terminator issues no kill for a session the launch adopted")
    func terminatorIssuesNoKillForAnAdoptedSession() async {
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        ledger.record(
            hostSessionID: surface,
            identity: live("$0", "wm-repo-abcd1234", 1_788_320_000),
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040)
        )
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            runForOutput: { _, _, _ in "$0\twm-repo-abcd1234\t1788320000\t35533\n" },
            environment: [:]
        )

        let outcome = await TmuxOwnedSessionTerminator(ledger: ledger, probe: probe)
            .terminate(hostSessionID: surface, requiringCreation: true)

        #expect(outcome == .notAttributable)
        #expect(await recorder.calls.isEmpty)
    }

    @MainActor
    @Test("The terminator kills a created session by the id the socket reports now")
    func terminatorKillsByFreshlyResolvedID() async throws {
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        ledger.record(
            hostSessionID: surface,
            identity: live("$4", "wm-repo-abcd1234", 1_788_328_041),
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040)
        )
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            runForOutput: { _, _, _ in
                "$0\tprobe-bystander\t1788320000\t35533\n$4\twm-repo-abcd1234\t1788328041\t35533\n"
            },
            environment: [:]
        )

        let outcome = await TmuxOwnedSessionTerminator(ledger: ledger, probe: probe)
            .terminate(hostSessionID: surface, requiringCreation: true)

        #expect(outcome == .killed(sessionID: "$4", name: "wm-repo-abcd1234"))
        let call = try #require(await recorder.calls.first)
        #expect(adjacent(call.arguments, "-t", "$4"))
    }

    @MainActor
    @Test("A socket that will not answer authorizes nothing")
    func unreadableSocketAuthorizesNothing() async {
        let ledger = TmuxSessionOwnershipLedger()
        let surface = UUID()
        ledger.record(
            hostSessionID: surface,
            identity: live("$4", "wm-repo-abcd1234", 1_788_328_041),
            launchedAt: Date(timeIntervalSince1970: 1_788_328_040)
        )
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            runForOutput: { _, _, _ in nil },
            environment: [:]
        )

        let outcome = await TmuxOwnedSessionTerminator(ledger: ledger, probe: probe)
            .terminate(hostSessionID: surface, requiringCreation: true)

        #expect(outcome == .socketUnavailable)
        #expect(await recorder.calls.isEmpty)
    }

    // MARK: - Helpers

    private func live(_ id: String, _ name: String, _ created: TimeInterval) -> TmuxLiveSession {
        TmuxLiveSession(
            sessionID: id, name: name, createdAt: Date(timeIntervalSince1970: created), serverPID: 35533)
    }

    private func adjacent(_ arguments: [String], _ first: String, _ second: String) -> Bool {
        for index in arguments.indices.dropLast()
        where arguments[index] == first && arguments[index + 1] == second {
            return true
        }
        return false
    }
}

/// Captures what actually reached the process boundary. Several tests here assert on
/// the *absence* of a call, which an exit-code stub cannot express.
private actor ArgumentRecorder {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func record(executable: String, arguments: [String]) {
        calls.append(Call(executable: executable, arguments: arguments))
    }
}
