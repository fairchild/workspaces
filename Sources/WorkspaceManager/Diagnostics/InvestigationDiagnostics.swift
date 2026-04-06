import Foundation

enum InvestigationDiagnostics {
    private static let focusEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_FOCUS_DIAGNOSTICS"] == "1"
    private static let sheetEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_SHEET_DIAGNOSTICS"] == "1"
    private static let terminalEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_TERMINAL_DIAGNOSTICS"] == "1"
    private static let inputEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_INPUT_DIAGNOSTICS"] == "1"

    static func emitFocus(phase: String, fields: [String: String] = [:]) {
        guard focusEnabled else { return }
        emit(metric: "focus_investigation", phase: phase, fields: fields)
    }

    static func emitSheet(phase: String, fields: [String: String] = [:]) {
        guard sheetEnabled else { return }
        emit(metric: "new_workspace_sheet_investigation", phase: phase, fields: fields)
    }

    static func emitTerminal(phase: String, fields: [String: String] = [:]) {
        guard terminalEnabled else { return }
        emit(metric: "terminal_investigation", phase: phase, fields: fields)
    }

    static func emitInput(phase: String, fields: [String: String] = [:]) {
        guard inputEnabled else { return }
        emit(metric: "input_investigation", phase: phase, fields: fields)
    }

    private static func emit(metric: String, phase: String, fields: [String: String]) {
        var components = [
            "[Perf]",
            "metric=\(metric)",
            "phase=\(sanitize(phase))",
        ]

        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            components.append("\(sanitize(key))=\(sanitize(value))")
        }

        NSLog("%@", components.joined(separator: " "))
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\t", with: "_")
    }
}
