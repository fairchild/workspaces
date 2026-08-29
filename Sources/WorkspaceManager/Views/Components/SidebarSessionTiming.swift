//
//  SidebarSessionTiming.swift
//  WorkspaceManager
//
//  The two clocks on the selected workspace row's status line: how long the agent session has
//  been running, which ticks once a second inside a leaf of its own, and how old the workspace
//  is, which is coarse enough to be read whenever the row happens to redraw.
//

import SwiftUI

/// Elapsed session time the way a stopwatch reads: `mm:ss` while under an hour, `h:mm:ss` once
/// past it. Minutes stay zero-padded so the label holds its width from the first second.
enum SessionElapsedFormatter {
    static func text(from startedAt: Date, to now: Date) -> String {
        text(elapsed: Int(now.timeIntervalSince(startedAt)))
    }

    /// A start that sits ahead of now is a clock we can't reconcile — a session registered
    /// before a system clock correction — so the label starts from zero rather than counting
    /// toward it.
    static func text(elapsed seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

/// How long a workspace has existed, in the single coarsest unit that still says something:
/// `4m`, `3h`, `5d`, `2y`. One unit only — beside a live timer the age is context, and a
/// second unit would ask to be read as precision it isn't.
enum WorkspaceAgeFormatter {
    static func text(from createdAt: Date, to now: Date) -> String {
        text(age: Int(now.timeIntervalSince(createdAt)))
    }

    static func text(age seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        guard hours >= 24 else { return "\(hours)h" }
        let days = hours / 24
        guard days >= 365 else { return "\(days)d" }
        return "\(days / 365)y"
    }
}

/// The ticking half of the status line, kept as small as a view can be. It takes the one fact
/// it needs — when the session started, which is fixed for that session's life — and owns the
/// clock that redraws it, so the per-second invalidation stops at this leaf and never reaches
/// the row, the list, or the sidebar.
struct SessionElapsedLabel: View {
    let startedAt: Date
    /// Fixes the clock for a still render — an evidence PNG, a test — which has no next second
    /// to wait for. Nil in the app, where the label runs its own.
    var referenceDate: Date? = nil

    var body: some View {
        if let referenceDate {
            Text(SessionElapsedFormatter.text(from: startedAt, to: referenceDate))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SessionElapsedFormatter.text(from: startedAt, to: context.date))
            }
        }
    }
}
