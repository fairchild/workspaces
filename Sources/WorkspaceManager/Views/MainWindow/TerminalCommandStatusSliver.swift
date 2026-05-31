import SwiftUI
import WorkspaceManagerCore

struct TerminalCommandStatusSliver: View {
    let status: LastCommandStatus?

    var body: some View {
        if let presentation = TerminalCommandStatusSliverPresentation(status: status) {
            HStack(spacing: 8) {
                statusGlyph(for: presentation)

                Text(presentation.primaryText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .layoutPriority(0)

                if let secondaryText = presentation.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.8))
                    .frame(height: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    @ViewBuilder
    private func statusGlyph(for presentation: TerminalCommandStatusSliverPresentation) -> some View {
        if presentation.isRunning {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(presentation.tint.color)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
    }
}

struct TerminalCommandStatusSliverPresentation: Equatable {
    enum Tint: Equatable {
        case running
        case success
        case failure
        case neutral

        var color: Color {
            switch self {
            case .running:
                return Color(nsColor: .controlAccentColor)
            case .success:
                return .green
            case .failure:
                return .red
            case .neutral:
                return .secondary
            }
        }
    }

    let primaryText: String
    let secondaryText: String?
    let accessibilityLabel: String
    let symbolName: String
    let tint: Tint
    let isRunning: Bool

    init?(status: LastCommandStatus?) {
        guard let status else { return nil }

        let commandText = status.commandLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommand = commandText?.isEmpty == false ? commandText : nil
        let durationText = status.duration.map(Self.durationText(for:))

        if status.isRunning {
            primaryText = displayCommand ?? "Running command..."
            secondaryText = displayCommand == nil ? nil : "Running"
            accessibilityLabel = displayCommand.map { "Running command, \($0)" } ?? "Running command"
            symbolName = "circle.dotted"
            tint = .running
            isRunning = true
            return
        }

        isRunning = false

        switch status.exitCode {
        case 0?:
            primaryText = displayCommand ?? "Last command succeeded"
            secondaryText = Self.joinedMetadata(["Exit 0", durationText])
            accessibilityLabel = Self.accessibilityLabel(
                state: "Last command succeeded",
                command: displayCommand,
                exitCode: 0,
                duration: durationText
            )
            symbolName = "checkmark.circle.fill"
            tint = .success

        case let exitCode?:
            primaryText = displayCommand ?? "Last command failed"
            secondaryText = Self.joinedMetadata(["Exited \(exitCode)", durationText])
            accessibilityLabel = Self.accessibilityLabel(
                state: "Last command failed",
                command: displayCommand,
                exitCode: exitCode,
                duration: durationText
            )
            symbolName = "xmark.circle.fill"
            tint = .failure

        case nil:
            primaryText = displayCommand ?? "Command finished"
            secondaryText = Self.joinedMetadata(["Finished", durationText])
            accessibilityLabel = Self.accessibilityLabel(
                state: "Command finished",
                command: displayCommand,
                exitCode: nil,
                duration: durationText
            )
            symbolName = "checkmark.circle"
            tint = .neutral
        }
    }

    static func durationText(for duration: TimeInterval) -> String {
        let seconds = max(0, duration)
        if seconds < 1 {
            return "<1s"
        }
        if seconds < 10 {
            let tenths = Int((seconds * 10).rounded())
            if tenths % 10 == 0 {
                return "\(tenths / 10)s"
            }
            return "\(tenths / 10).\(tenths % 10)s"
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }

        let wholeSeconds = Int(seconds.rounded())
        let minutes = wholeSeconds / 60
        let remainingSeconds = wholeSeconds % 60
        let paddedSeconds = remainingSeconds < 10 ? "0\(remainingSeconds)" : "\(remainingSeconds)"
        return "\(minutes)m \(paddedSeconds)s"
    }

    private static func joinedMetadata(_ values: [String?]) -> String? {
        let pieces = values.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " - ")
    }

    private static func accessibilityLabel(
        state: String,
        command: String?,
        exitCode: Int?,
        duration: String?
    ) -> String {
        var pieces = [state]
        if let command, !command.isEmpty {
            pieces.append(command)
        }
        if let exitCode {
            pieces.append("exit code \(exitCode)")
        }
        if let duration {
            pieces.append("duration \(duration)")
        }
        return pieces.joined(separator: ", ")
    }
}
