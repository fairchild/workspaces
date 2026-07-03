//
//  RestoreSessionsBanner.swift
//  WorkspaceManager
//
//  Quiet, non-blocking main-window affordance offering to reopen the terminal
//  sessions from the previous run. Opt-in: ignoring it leaves the app fully
//  usable. Matches the existing top-of-window banner idiom.
//

import SwiftUI

struct RestoreSessionsBanner: View {
    let sessionCount: Int
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Resume your previous session\(sessionCount == 1 ? "" : "s")?")
                        .font(.callout.weight(.semibold))
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onRestore) {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("restore-sessions.restore")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityIdentifier("restore-sessions.dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("restore-sessions.banner")
    }

    private var summaryText: String {
        "\(sessionCount) terminal \(sessionCount == 1 ? "session" : "sessions") from your last run."
    }
}
