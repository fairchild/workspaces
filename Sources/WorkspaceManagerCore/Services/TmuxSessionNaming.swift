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
