//
//  SyntheticRunRoot.swift
//  WorkspaceManagerCore
//
//  Resolves WORKSPACES_SYNTHETIC_ROOT, the synthetic-run isolation boundary:
//  when a smoke or capture run sets it, workspace filesystem roots resolve
//  inside that directory so the run never reads or writes the owner's real
//  workspaces root.
//

import Foundation

public enum SyntheticRunRoot {
    public static let environmentKey = "WORKSPACES_SYNTHETIC_ROOT"

    public static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let rawValue = environment[environmentKey] else { return nil }
        let path = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
