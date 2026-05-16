//
//  DiagnosticsValueFormatting.swift
//  WorkspaceManager
//
//  Shared display formatting for runtime diagnostics values.
//

import Foundation

enum DiagnosticsValueFormatting {
    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
