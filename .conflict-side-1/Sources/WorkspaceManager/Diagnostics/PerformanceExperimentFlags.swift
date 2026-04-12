import Foundation

enum PerformanceExperimentFlags {
    static let minimalToolbar =
        ProcessInfo.processInfo.environment["WORKSPACES_PERF_MINIMAL_TOOLBAR"] == "1"
}
