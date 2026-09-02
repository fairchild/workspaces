//
//  SidebarSessionTiming.swift
//  WorkspaceManager
//
//  The two clocks on the selected workspace row's status line: how long the agent session has
//  been running, which ticks once a second, and how old the workspace is, which ticks once a
//  minute. Each owns its clock inside a leaf of its own, so the per-tick invalidation stops
//  there and never reaches the row, the list, or the sidebar.
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

/// The workspace age, in a leaf that owns its own minute clock.
///
/// It needs one for the same reason the elapsed label does, and for one more: since #1366 a
/// sidebar row only rebuilds when its equality state moves, and nothing about a passing minute
/// moves it. Reading `Date()` in the row's body left `59m` on screen indefinitely — past the
/// hour, past the day — beside an elapsed timer that was still counting. `createdAt` is fixed
/// for the workspace's life, so the leaf takes it and reschedules itself.
///
/// The schedule is anchored to `createdAt` rather than to `.now`, so a tick lands when the age
/// actually turns over instead of up to a minute after it. `tickOrigin` walks that grid forward
/// to the last boundary at or before now: a schedule origin years in the past is well-defined,
/// but a near one is cheaper to reason about and keeps the arithmetic in view.
struct WorkspaceAgeLabel: View {
    let createdAt: Date
    /// Fixes the clock for a still render — an evidence PNG, a test — which has no next minute
    /// to wait for. Nil in the app, where the label runs its own.
    var referenceDate: Date? = nil

    var body: some View {
        if let referenceDate {
            Text(WorkspaceAgeFormatter.text(from: createdAt, to: referenceDate))
        } else {
            TimelineView(.periodic(from: tickOrigin, by: 60)) { context in
                Text(WorkspaceAgeFormatter.text(from: createdAt, to: context.date))
            }
        }
    }

    private var tickOrigin: Date {
        let elapsed = Date.now.timeIntervalSince(createdAt)
        guard elapsed > 60 else { return createdAt }
        return createdAt.addingTimeInterval((elapsed / 60).rounded(.down) * 60)
    }
}
