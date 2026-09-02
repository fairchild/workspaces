//
//  RuntimeProcessAlertRow.swift
//  WorkspaceManager
//
//  The sidebar's attention strip for a runaway process (#1368): one line naming
//  what is eating the machine, one line saying how fast, and the two things a
//  person wants — stop it, or stop being told about it. Sits above the search
//  row, in the sidebar's only fixed chrome above the list, so it is present
//  without occupying a row that scrolls away.
//

import SwiftUI
import WorkspaceManagerCore

struct RuntimeProcessAlertStrip: View {
    let alerts: [RuntimeProcessAlert]
    /// Processes a stop was asked for and refused.
    var unstoppable: Set<Int32> = []
    let onStop: (RuntimeProcessAlert) -> Void
    let onDismiss: (RuntimeProcessAlert) -> Void

    var body: some View {
        if !alerts.isEmpty {
            VStack(spacing: 0) {
                // Only the worst offender gets the strip. A sidebar is not a
                // process table, and the pane it links to already is one.
                ForEach(alerts.prefix(RuntimeProcessAlertStrip.visibleLimit)) { alert in
                    RuntimeProcessAlertRow(
                        alert: alert,
                        stopFailed: unstoppable.contains(alert.pid),
                        onStop: { onStop(alert) },
                        onDismiss: { onDismiss(alert) }
                    )
                }

                if alerts.count > RuntimeProcessAlertStrip.visibleLimit {
                    Text("\(alerts.count - RuntimeProcessAlertStrip.visibleLimit) more in Diagnostics")
                        .font(SidebarChrome.TypeStyle.footerLabel)
                        .foregroundStyle(SidebarChrome.Foreground.quietSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SidebarChrome.Metrics.chromeBarHorizontalPadding)
                        .padding(.bottom, SidebarChrome.Metrics.chromeBarVerticalPadding)
                        .background(SidebarChrome.Fill.surface)
                }

                Divider()
            }
            .accessibilityIdentifier("runtime-process-alert.strip")
        }
    }

    static let visibleLimit = 2
}

struct RuntimeProcessAlertRow: View {
    let alert: RuntimeProcessAlert
    var stopFailed: Bool = false
    let onStop: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // Two lines, each with the reading on the left and the action on the
        // right. A sidebar is ~250 pt wide, and the first draft put the name, the
        // size, a Stop button and a dismiss button on one line — which truncated
        // the middle of the sentence and left "codex is…g 2.8 GB" on screen. The
        // numbers are the whole point of the strip, so they get fixed width and
        // the process name is what gives way.
        HStack(alignment: .top, spacing: SidebarChrome.Metrics.rowContentSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(SidebarChrome.TypeStyle.statusGlyph)
                .foregroundStyle(.orange)
                .frame(width: SidebarChrome.Metrics.iconColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(alert.name)
                        .font(SidebarChrome.TypeStyle.rowTitle(emphasized: true))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(Self.format(bytes: alert.footprintBytes))
                        .font(SidebarChrome.TypeStyle.rowTitle(emphasized: true))
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(detail)
                        .font(SidebarChrome.TypeStyle.statusMeta)
                        .foregroundStyle(SidebarChrome.Foreground.quietSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    // Stop is offered only for the app's own descendants. A
                    // process that merely has its working directory inside a
                    // workspace was started by somebody else, and killing a
                    // stranger's process because of where it happens to be
                    // sitting is not the app's call to make.
                    if alert.isAppDescendant {
                        Button("Stop", action: onStop)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .layoutPriority(1)
                            .help("Send \(alert.name) (pid \(alert.pid)) a stop signal")
                            .accessibilityIdentifier("runtime-process-alert.stop")
                    }
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(
                        width: SidebarChrome.Metrics.headerActionSide,
                        height: SidebarChrome.Metrics.headerActionSide
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(SidebarChrome.Foreground.quietSecondary)
            .help("Stop reporting this process")
            .accessibilityIdentifier("runtime-process-alert.dismiss")
        }
        .padding(.horizontal, SidebarChrome.Metrics.chromeBarHorizontalPadding)
        .padding(.vertical, SidebarChrome.Metrics.chromeBarVerticalPadding)
        .background(SidebarChrome.Fill.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(alert.name) is using \(Self.format(bytes: alert.footprintBytes)). \(detail)")
    }

    /// Says which rule fired, because the two mean different things: a ceiling
    /// alert is about size now, a growth alert is about where it is heading.
    private var detail: String {
        if stopFailed {
            return "would not stop · pid \(alert.pid)"
        }
        switch alert.trigger {
        case .footprintCeiling:
            return alert.isAppDescendant
                ? "started by WorkSpaces · pid \(alert.pid)"
                : "in a workspace · pid \(alert.pid)"
        case .growthRate:
            return "+\(Self.format(bytes: alert.growthBytesPerHour))/h · pid \(alert.pid)"
        }
    }

    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: max(bytes, 0))
    }
}

#Preview("Growth alert") {
    RuntimeProcessAlertStrip(
        alerts: [
            RuntimeProcessAlert(
                pid: 4_412,
                name: "codex",
                trigger: .growthRate,
                footprintBytes: 3_006_477_107,
                growthBytesPerHour: 171_798_692,
                sampleCount: 22,
                observedSince: Date(timeIntervalSinceNow: -3_600),
                isAppDescendant: true
            )
        ],
        onStop: { _ in },
        onDismiss: { _ in }
    )
    .frame(width: 260)
}
