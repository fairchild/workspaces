import Foundation

enum InvestigationDiagnostics {
    private enum InputMode: String {
        case disabled
        case summary
        case detailed
    }

    private struct InputAggregate {
        var eventAgeValues: [Double] = []
        var handlerDurationValues: [Double] = []
        var surfaceMissingCount = 0
        var windowNotKeyCount = 0

        var count: Int {
            eventAgeValues.count
        }

        mutating func record(
            eventAgeMs: Double,
            handlerDurationMs: Double,
            surfaceMissing: Bool,
            windowKey: Bool
        ) {
            eventAgeValues.append(eventAgeMs)
            handlerDurationValues.append(handlerDurationMs)
            if surfaceMissing {
                surfaceMissingCount += 1
            }
            if !windowKey {
                windowNotKeyCount += 1
            }
        }

        mutating func takeIfReady(batchSize: Int) -> InputAggregate? {
            guard count >= batchSize else { return nil }
            let snapshot = self
            self = InputAggregate()
            return snapshot
        }
    }

    private static let focusEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_FOCUS_DIAGNOSTICS"] == "1"
    private static let sheetEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_SHEET_DIAGNOSTICS"] == "1"
    private static let terminalEnabled =
        ProcessInfo.processInfo.environment["WORKSPACES_TERMINAL_DIAGNOSTICS"] == "1"
    private static let inputMode: InputMode = {
        let rawValue = ProcessInfo.processInfo.environment["WORKSPACES_INPUT_DIAGNOSTICS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch rawValue {
        case "1", "detailed":
            return .detailed
        case "summary":
            return .summary
        default:
            return .disabled
        }
    }()
    nonisolated(unsafe) private static var inputAggregate = InputAggregate()
    private static let inputSummaryBatchSize = 12

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
        guard inputMode == .detailed else { return }
        emit(metric: "input_investigation", phase: phase, fields: fields)
    }

    static func recordInputHandled(
        eventAgeMs: Double,
        handlerDurationMs: Double,
        surfaceMissing: Bool,
        windowKey: Bool,
        detailedFields: [String: String]
    ) {
        switch inputMode {
        case .disabled:
            return
        case .detailed:
            emit(metric: "input_investigation", phase: "key_down_handled", fields: detailedFields)
        case .summary:
            inputAggregate.record(
                eventAgeMs: eventAgeMs,
                handlerDurationMs: handlerDurationMs,
                surfaceMissing: surfaceMissing,
                windowKey: windowKey
            )
            guard let snapshot = inputAggregate.takeIfReady(batchSize: inputSummaryBatchSize) else {
                return
            }
            emit(
                metric: "input_investigation",
                phase: "key_down_summary",
                fields: [
                    "count": "\(snapshot.count)",
                    "event_age_max_ms": format(snapshot.eventAgeValues.max() ?? 0),
                    "event_age_mean_ms": format(mean(snapshot.eventAgeValues)),
                    "event_age_median_ms": format(median(snapshot.eventAgeValues)),
                    "handler_duration_max_ms": format(snapshot.handlerDurationValues.max() ?? 0),
                    "handler_duration_mean_ms": format(mean(snapshot.handlerDurationValues)),
                    "handler_duration_median_ms": format(median(snapshot.handlerDurationValues)),
                    "surface_missing_count": "\(snapshot.surfaceMissingCount)",
                    "window_not_key_count": "\(snapshot.windowNotKeyCount)",
                ]
            )
        }
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

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
