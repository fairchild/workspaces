import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TmuxSessionProbe")
struct TmuxSessionProbeTests {
    @Test("Exit code 0 means the session is alive")
    func exitZeroIsAlive() async {
        let probe = TmuxSessionProbe(run: { _, _, _ in 0 }, environment: [:])
        #expect(await probe.isSessionAlive("wm-repo-abcd1234"))
    }

    @Test("Non-zero exit means the session is not alive")
    func nonZeroExitIsNotAlive() async {
        let probe = TmuxSessionProbe(run: { _, _, _ in 1 }, environment: [:])
        #expect(await probe.isSessionAlive("wm-repo-abcd1234") == false)
    }

    @Test("A launch failure (nil exit) is treated as not alive")
    func launchFailureIsNotAlive() async {
        let probe = TmuxSessionProbe(run: { _, _, _ in nil }, environment: [:])
        #expect(await probe.isSessionAlive("wm-repo-abcd1234") == false)
    }

    @Test("Probe invokes has-session on the workspaces socket with an exact-match target")
    func buildsExactMatchHasSessionCommand() async throws {
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            environment: [:]
        )
        _ = await probe.isSessionAlive("wm-repo-abcd1234")

        let calls = await recorder.calls
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments.contains("tmux"))
        #expect(call.arguments.contains("has-session"))
        // -L workspaces isolates from the user's default tmux server.
        #expect(adjacent(call.arguments, "-L", "workspaces"))
        // "=name" forces exact match so a hash suffix can't prefix-collide.
        #expect(adjacent(call.arguments, "-t", "=wm-repo-abcd1234"))
    }

    private func adjacent(_ arguments: [String], _ first: String, _ second: String) -> Bool {
        guard let index = arguments.firstIndex(of: first), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == second
    }
}

private actor ArgumentRecorder {
    private(set) var calls: [(executable: String, arguments: [String])] = []

    func record(executable: String, arguments: [String]) {
        calls.append((executable, arguments))
    }
}
