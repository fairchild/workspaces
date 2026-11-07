// Debug-only proof of the native terminal path: replays a recorded agent
// turn through libghostty-vt in small chunks, so redraws (a progress line
// rewritten in place, a spinner replaced by cursor-up) happen live on the
// phone exactly as they would from a byte stream. Launch with
// `-terminal-preview`, or open it from the paired view's menu.
#if DEBUG
    import SwiftUI
    import TerminalScreen

    @MainActor
    @Observable
    final class TerminalReplay {
        private(set) var snapshot: TerminalSnapshot?
        private(set) var failure: String?
        private var terminal: VirtualTerminal?

        func play(_ recording: Data, chunk: Int = 24, every interval: Duration = .milliseconds(30)) async {
            do {
                let terminal = try VirtualTerminal(columns: 46, rows: 14)
                self.terminal = terminal
                for start in stride(from: 0, to: recording.count, by: chunk) {
                    terminal.write(recording[start..<min(start + chunk, recording.count)])
                    snapshot = try terminal.snapshot()
                    try await Task.sleep(for: interval)
                }
            } catch is CancellationError {
            } catch {
                failure = String(describing: error)
            }
        }
    }

    struct TerminalPreviewView: View {
        @State private var replay = TerminalReplay()
        @State private var run = 0

        private static let recording = Bundle.main.url(forResource: "agent-turn", withExtension: "vt")
            .flatMap { try? Data(contentsOf: $0) }

        var body: some View {
            NavigationStack {
                content
                    .navigationTitle("Terminal (vt \(VirtualTerminal.libraryVersion))")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Replay", systemImage: "arrow.clockwise") { run += 1 }
                    }
            }
            .task(id: run) {
                guard let recording = Self.recording else { return }
                replay = TerminalReplay()
                await replay.play(recording)
            }
        }

        @ViewBuilder private var content: some View {
            if let failure = replay.failure {
                ContentUnavailableView(
                    "Terminal failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else if Self.recording == nil {
                ContentUnavailableView("No recording bundled", systemImage: "doc.questionmark")
            } else if let snapshot = replay.snapshot {
                TerminalScreenView(snapshot: snapshot, fontSize: 12)
            } else {
                ProgressView()
            }
        }
    }

    #Preview {
        TerminalPreviewView()
    }
#endif
