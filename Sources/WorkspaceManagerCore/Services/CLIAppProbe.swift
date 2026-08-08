//
//  CLIAppProbe.swift
//  WorkspaceManagerCore
//
//  The bound and the failure taxonomy for the CLI's passive app-inventory probe — the
//  socket read behind `ws list`, `repo list`, and selector resolution. The deadline lives
//  here because two surfaces state it (the probe and `workspaces help`), and the outcomes
//  exist so a probe that misses can say which way it missed instead of falling back mute.
//

import Foundation

public enum CLIAppProbe {
    /// Send/receive deadline for the inventory probe, in seconds. Short on purpose: nobody asked
    /// for this request. It runs behind `ws list`, `repo list`, and selector resolution to enrich
    /// output the CLI can already produce alone, so a hung or wedged app has to cost the shell
    /// noticeably less than the interactive operator verbs a user typed and is waiting on. Half a
    /// second clears a healthy local round trip (unix socket, one main-actor hop) with room for a
    /// mid-render app, and reads as immediate when it does fire.
    ///
    /// It reaches the socket as SO_RCVTIMEO/SO_SNDTIMEO, so it bounds each blocking syscall rather
    /// than the call as a whole: an app that trickles a chunk per interval could still outlast it.
    /// It converts the failure mode that matters — an app that accepts the connection and then
    /// stops answering — from an unbounded hang into a fall back to the appless plane.
    public static let deadline: TimeInterval = 0.5

    /// The deadline as prose states it. `workspaces help` renders this rather than its own
    /// spelling, so the number a caller reads before scripting a loop is the number the socket
    /// actually gets.
    public static var deadlineDescription: String {
        let rendered = deadline == deadline.rounded() ? String(Int(deadline)) : String(deadline)
        return "\(rendered)s"
    }

    /// Why a probe did or did not produce an app inventory. The appless plane is the fallback for
    /// every failure, but the four ways to get there are not the same operator problem, and the
    /// help text promises two planes — so a miss says which one it hit.
    public enum Outcome: Equatable, Sendable {
        case reachable
        /// No readable operator credential. `appRunning` separates "there is no app" (the appless
        /// machine, nothing to report) from "the app is up but mints no credential" (the
        /// 2026-08-07 probe scenario, where the two planes silently diverge).
        case noOperatorCredential(appRunning: Bool)
        case listenerUnreachable
        case timedOut(TimeInterval)
        case unreadableResponse

        /// One line for stderr, or nil when there is nothing an operator would want said: a probe
        /// that worked, or a machine with no app running, where the CLI-local plane *is* the whole
        /// story. Callers decide audibility; these are only the words.
        public var hint: String? {
            switch self {
            case .reachable:
                return nil
            case .noOperatorCredential(let appRunning):
                return appRunning ? CLIPlaneComposer.operatorCredentialMissingHint : nil
            case .listenerUnreachable:
                return "note: an operator credential exists but nothing is listening on the automation "
                    + "socket, so this shows the CLI-local plane only."
            case .timedOut(let seconds):
                return "note: the running app did not answer the inventory probe within "
                    + "\(Self.render(seconds)), so this shows the CLI-local plane only."
            case .unreadableResponse:
                return "note: the running app's inventory reply could not be read, so this shows the "
                    + "CLI-local plane only."
            }
        }

        private static func render(_ seconds: TimeInterval) -> String {
            let rendered = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
            return "\(rendered)s"
        }
    }

    /// Classifies a probe failure into the outcome that explains it. Socket-level errors carry
    /// their own distinction; anything else (a decode failure, a refusal envelope the CLI turned
    /// into its own error) reached the app and came back unusable.
    public static func outcome(forProbeError error: Error) -> Outcome {
        guard let clientError = error as? AutomationSocketClient.ClientError else {
            return .unreadableResponse
        }
        switch clientError {
        case .socketPathTooLong, .socketOpenFailed, .connectFailed:
            return .listenerUnreachable
        case .timedOut(let seconds):
            return .timedOut(seconds)
        case .writeFailed, .readFailed, .invalidHTTPResponse:
            return .unreadableResponse
        }
    }
}
