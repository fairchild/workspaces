//
//  TmuxSessionNaming.swift
//  WorkspaceManagerCore
//
//  Canonical tmux session naming for .tmuxPerSession mode. One derivation shared
//  by launch (GhosttyTerminalConfig), continuity recording (LocalStateStore), and
//  foreground probing, so a recorded name always matches what launch would run.
//

import Foundation

public enum TmuxSessionNaming {
    /// Deterministic directory-derived name (`wm-<base>-<hash8>`): stable across
    /// runs so a relaunch `new-session -A`-attaches to a surviving session.
    public static func defaultName(for directory: URL) -> String {
        let normalizedPath = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let baseComponent = directory.lastPathComponent.isEmpty ? "session" : directory.lastPathComponent
        let sanitizedBase = sanitizeSessionComponent(baseComponent)
        let hash = fnv1a64(normalizedPath)
        let hashPrefix = String(format: "%016llx", hash).prefix(8)
        return "wm-\(sanitizedBase)-\(hashPrefix)"
    }

    /// Name for a non-primary split pane: the directory-derived name plus a
    /// pane-session suffix, so sibling panes sharing one directory get distinct
    /// tmux sessions instead of `-A`-attaching to the primary's (#1232).
    public static func splitPaneName(for directory: URL, paneSessionID: UUID) -> String {
        let suffix = paneSessionID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(8)
        return "\(defaultName(for: directory))-p\(suffix)"
    }

    /// Whether `name` has exactly the shape `splitPaneName(for:paneSessionID:)` produces for
    /// `directory` — the app's own directory-derived base plus `-p` and 8 lowercase hex digits.
    ///
    /// This is what teardown asks before reclaiming a tmux session on close (#1390): a session
    /// override is otherwise indistinguishable from an arbitrary live session an adoption gesture
    /// bound to (#1233's split-pane case set `tmuxSessionNameOverride` to any name differing from
    /// the directory derivation, and teardown killed anything shaped that way). Checking the exact
    /// shape rather than "differs from the derivation" is what keeps that kill scoped to sessions
    /// the app generated the name for, however that override reached the session — a stored
    /// provenance flag could be dropped by a future code path; a shape derived purely from the
    /// name and the directory cannot be.
    public static func isPaneScopedName(_ name: String, for directory: URL) -> Bool {
        let prefix = "\(defaultName(for: directory))-p"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count == 8 else { return false }
        return suffix.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Name for a caller-labelled sibling session: the directory-derived name plus
    /// the sanitized label. A second headless agent in one workspace needs a handle
    /// of its own, and one the caller chose is one they can find again — unlike the
    /// pane-session suffix, which only launch knows.
    public static func labeledName(for directory: URL, label: String) -> String {
        let sanitized = sanitizeSessionComponent(label)
        return "\(defaultName(for: directory))-\(sanitized)"
    }

    private static func sanitizeSessionComponent(_ value: String) -> String {
        let transformed = value.lowercased().map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        let collapsed = String(transformed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if collapsed.isEmpty {
            return "session"
        }

        return String(collapsed.prefix(20))
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01b3
        }
        return hash
    }
}
