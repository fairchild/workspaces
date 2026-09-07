//
//  RenderSuiteIsolation.swift
//  WorkspaceManagerAppTests
//

import Foundation

/// Whether this process is one where a suite that measures SwiftUI render passes can trust its
/// own numbers.
///
/// Such a suite needs the main run loop to itself: a display cycle driven by another suite lands
/// inside the window between two rebuild counts, and there is no assertion that can tell that
/// apart from the behaviour under test. Locally the full run is fast enough that it has never
/// been observed; on a loaded CI runner it is routine (#1542).
///
/// CI therefore runs those suites in their own `swift test` invocation with
/// `WORKSPACES_RENDER_TESTS=1`, and skips them in the parallel run that everything else uses.
enum RenderSuiteIsolation {
    static var isSatisfied: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == nil || environment["WORKSPACES_RENDER_TESTS"] != nil
    }
}
