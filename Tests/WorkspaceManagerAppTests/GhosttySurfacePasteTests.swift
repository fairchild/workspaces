//
//  GhosttySurfacePasteTests.swift
//  WorkspaceManagerAppTests
//
//  Judges each text entry point by the bytes a program actually reads from its PTY. Every test
//  runs a real libghostty surface whose program records its input to a file: pastes are framed
//  once the program enables bracketed paste (mode 2004) and typed keys never are, paste
//  protection holds multi-line text an unbracketed program would run line by line, and the
//  automation input verb's two calls deliver text to a shell byte for byte.
//

import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("Ghostty surface paste routing", .serialized)
@MainActor
struct GhosttySurfacePasteTests {
    private static let pasteStart = "\u{1b}[200~"
    private static let pasteEnd = "\u{1b}[201~"

    @Test("Pasted text is framed once the program enables bracketed paste; typed text beside it is not")
    func bracketedPasteFramesPastesButNotTypedKeys() async throws {
        let program = try await PTYRecorder.start(.rawBracketed)
        defer { program.cleanUp() }

        program.type("hi")
        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: "echo paste") == .delivered)
        program.type("ok")

        let expected = "hi" + Self.pasteStart + "echo paste" + Self.pasteEnd + "ok"
        #expect(try await program.received(byteCount: expected.utf8.count) == expected)
    }

    @Test("A paste reaches a program without bracketed paste unframed and unchanged")
    func unbracketedPasteArrivesUnframed() async throws {
        let program = try await PTYRecorder.start(.raw)
        defer { program.cleanUp() }

        let text = "echo 'héllo' $HOME ✓"
        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: text) == .delivered)

        #expect(try await program.received(byteCount: text.utf8.count) == text)
    }

    @Test("Multi-line text pastes as one framed unit into a program with bracketed paste")
    func multiLinePasteIntoBracketedProgramIsDelivered() async throws {
        let program = try await PTYRecorder.start(.rawBracketed)
        defer { program.cleanUp() }

        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: "one\ntwo") == .delivered)

        let expected = Self.pasteStart + "one\ntwo" + Self.pasteEnd
        #expect(try await program.received(byteCount: expected.utf8.count) == expected)
    }

    @Test("Paste protection holds multi-line text for a program without bracketed paste")
    func pasteProtectionHoldsMultiLineTextWhenUnbracketed() async throws {
        let program = try await PTYRecorder.start(.raw)
        defer { program.cleanUp() }

        let held = GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: "rm -rf build\necho done")
        #expect(held == .heldByPasteProtection)

        // The sentinel is the first byte the program ever reads: the held paste sent nothing.
        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: "sentinel") == .delivered)
        #expect(try await program.received(byteCount: "sentinel".utf8.count) == "sentinel")
    }

    @Test("Paste protection holds text carrying an end-of-paste marker even when bracketed")
    func pasteProtectionHoldsFrameEscapeWhenBracketed() async throws {
        let program = try await PTYRecorder.start(.rawBracketed)
        defer { program.cleanUp() }

        let escape = "harmless" + Self.pasteEnd + "touch pwned"
        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: escape) == .heldByPasteProtection)

        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: "sentinel") == .delivered)
        let expected = Self.pasteStart + "sentinel" + Self.pasteEnd
        #expect(try await program.received(byteCount: expected.utf8.count) == expected)
    }

    @Test("The automation input verb's paste and submit deliver a line to a shell byte for byte")
    func automationInputReachesShellByteForByte() async throws {
        let program = try await PTYRecorder.start(.shellLine)
        defer { program.cleanUp() }

        // The verb is these two calls: the text as a paste, then Return as a key event.
        let line = "printf '%s\\n' \"héllo wörld\" $HOME ~/x\t✓ 'it''s' \\t"
        #expect(GhosttySurfaceTextInputBridge.pasteText(into: program.view, text: line) == .delivered)
        #expect(GhosttySurfaceTextInputBridge.sendAutomationReturn(into: program.view))

        #expect(try await program.received(byteCount: line.utf8.count) == line)
    }

    @Test("IME commit text stays on the text path, which paste protection does not hold")
    func imeCommitSkipsPasteProtection() async throws {
        let program = try await PTYRecorder.start(.raw)
        defer { program.cleanUp() }

        // Outside a key event `insertText` is an IME commit. The paste path would hold this
        // text; the text path delivers it, converting the newline as an unbracketed paste does.
        program.view.insertText("日本\n語", replacementRange: NSRange(location: NSNotFound, length: 0))

        let expected = "日本\r語"
        #expect(try await program.received(byteCount: expected.utf8.count) == expected)
    }

    @Test("A launch command the app composed skips paste protection")
    func launchCommandSkipsPasteProtection() async throws {
        let program = try await PTYRecorder.start(.raw)
        defer { program.cleanUp() }

        #expect(GhosttySurfaceTextInputBridge.writeLaunchCommand(into: program.view, text: "cd /tmp\nexec claude"))

        let expected = "cd /tmp\rexec claude"
        #expect(try await program.received(byteCount: expected.utf8.count) == expected)
    }
}

/// A live surface whose program appends every byte it reads to a file. `raw` and
/// `rawBracketed` put the TTY in raw mode so nothing is echoed, buffered or translated, and
/// `rawBracketed` enables mode 2004 first. `shellLine` reads one line the way a shell's `read`
/// does, in the TTY's default cooked mode, and records it without its newline.
@MainActor
private final class PTYRecorder {
    enum Program {
        case raw
        case rawBracketed
        case shellLine
    }

    static let readyTitle = "paste-probe-ready"

    let view: GhosttySurfaceView
    private let directory: URL
    private let output: URL
    private let budget: TimeInterval

    private init(view: GhosttySurfaceView, directory: URL, output: URL, budget: TimeInterval) {
        self.view = view
        self.directory = directory
        self.output = output
        self.budget = budget
    }

    /// Starts the program and returns once it reports ready through its window title. The
    /// title follows the mode change in the same output stream, so Ghostty has applied the
    /// mode by the time the title is visible. The wait budget is measured before the surface
    /// exists, so the measuring launch never competes with the program it times.
    static func start(_ program: Program) async throws -> PTYRecorder {
        let budget = await LaunchBudget.deadline(
            launches: launchesPerWait, floor: waitFloor, ceiling: waitCeiling)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("program.sh")
        let output = directory.appendingPathComponent("received")
        try source(for: program).write(to: script, atomically: true, encoding: .utf8)

        let view = GhosttySurfaceView(customCommand: "/bin/sh '\(script.path)' '\(output.path)'")
        let recorder = PTYRecorder(view: view, directory: directory, output: output, budget: budget)
        try #require(view.surface != nil, "libghostty did not create a surface")
        try #require(
            await recorder.poll { view.terminalTitle == readyTitle },
            "the program never reported ready"
        )
        return recorder
    }

    /// Presses and releases each character's key, handing its text to Ghostty's key encoder
    /// the way `GhosttySurfaceInputRouter.keyDown` does for typed characters.
    func type(_ text: String) {
        let strokes: [(NSEvent.EventType, ghostty_input_action_e)] = [
            (.keyDown, GHOSTTY_ACTION_PRESS),
            (.keyUp, GHOSTTY_ACTION_RELEASE),
        ]
        for character in text {
            let characters = String(character)
            for (type, action) in strokes {
                guard
                    let event = NSEvent.keyEvent(
                        with: type,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0,
                        context: nil,
                        characters: characters,
                        charactersIgnoringModifiers: characters,
                        isARepeat: false,
                        keyCode: Self.keyCode(for: character)
                    )
                else { continue }
                _ = view.keyAction(action, event: event, text: type == .keyDown ? characters : nil)
            }
        }
    }

    /// What the program has read, once it has read at least `byteCount` bytes.
    func received(byteCount: Int) async throws -> String {
        let output = output
        let read = { (try? Data(contentsOf: output)) ?? Data() }
        let arrived = await poll { read().count >= byteCount }
        let text = String(decoding: read(), as: UTF8.self)
        try #require(arrived, "the program read fewer than \(byteCount) bytes: \(text.debugDescription)")
        return text
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Each wait covers one program launch (`/bin/sh` running the probe script) and its answer.
    /// The budget is that many of this machine's measured launch round trips (`LaunchBudget`),
    /// floored so a fast machine still fails quickly and capped so a pathological baseline
    /// cannot hang the run.
    private static let launchesPerWait = 6.0
    private static let waitFloor: TimeInterval = 30
    private static let waitCeiling: TimeInterval = 300

    /// Waits on an observable change within the launch-sized budget, widened once on a miss if
    /// the machine has slowed since it was measured. The budget only bounds a failure: a
    /// passing run returns as soon as the program has answered.
    private func poll(_ condition: @MainActor () -> Bool) async -> Bool {
        if await Self.poll(seconds: budget, condition) { return true }
        let refreshed = await LaunchBudget.deadline(
            launches: Self.launchesPerWait, floor: Self.waitFloor, ceiling: Self.waitCeiling,
            refreshing: true)
        guard refreshed > budget else { return false }
        return await Self.poll(seconds: refreshed - budget, condition)
    }

    private static func poll(seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func keyCode(for character: Character) -> UInt16 {
        let ansi: [Character: UInt16] = ["h": 0x04, "i": 0x22, "o": 0x1F, "k": 0x28]
        return ansi[character] ?? 0x31
    }

    private static func source(for program: Program) -> String {
        let ready = "printf '\\033]2;\(readyTitle)\\007'"
        switch program {
        case .raw, .rawBracketed:
            return """
                out="$1"
                : > "$out"
                stty raw -echo
                \(program == .rawBracketed ? "printf '\\033[?2004h'" : ":")
                \(ready)
                exec cat >> "$out"
                """
        case .shellLine:
            return """
                out="$1"
                \(ready)
                IFS= read -r line
                printf '%s' "$line" > "$out.partial"
                mv "$out.partial" "$out"
                exec cat > /dev/null
                """
        }
    }
}
