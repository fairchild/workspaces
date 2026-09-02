//
//  UIFixtureRuntimeAlertBootstrap.swift
//  WorkspaceManager
//
//  Fixture-mode staging for the sidebar's runaway-process alert. The real strip is fed by a
//  live sweep of the machine, which on a dev box may or may not hold a genuine runaway — noise
//  that would make fixture captures machine-dependent. In fixture mode the sweep is replaced
//  wholesale: a deterministic synthetic alert when the scenario asks for one, nothing
//  otherwise, and no polling either way.
//
//  Debug-only, following #1235/#1237: the release build carries the release stub, so the
//  arming env key never reaches a release binary. `scripts/check-release-harness-absence.sh`
//  enforces that absence.
//

import Foundation
import WorkspaceManagerCore

enum UIFixtureRuntimeAlertBootstrap {
    #if DEBUG
        static let seedEnvKey = "WORKSPACES_UI_FIXTURE_SEED_RUNAWAY_ALERT"

        /// The alerts fixture mode substitutes for the live sweep: a synthetic runaway when
        /// seeding is requested, `[]` for every other fixture launch (keeping the `clean`
        /// golden deterministic), `nil` outside fixture mode (the real sweep proceeds).
        static func fixtureAlerts(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [RuntimeProcessAlert]? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            guard environment[seedEnvKey] == "1" else { return [] }
            return [syntheticAlert()]
        }

        /// The 2026-08-23 `codex` runaway as it would have been caught: 2.8 GB and climbing at
        /// the 164 MB/h that leak actually averaged, well under the ceiling, flagged by the
        /// growth rule alone. Fixed values so the rendered copy never varies between captures.
        static func syntheticAlert() -> RuntimeProcessAlert {
            RuntimeProcessAlert(
                pid: 4_412,
                name: "codex",
                trigger: .growthRate,
                footprintBytes: 3_006_477_107,
                growthBytesPerHour: 171_798_692,
                sampleCount: 22,
                observedSince: Date(timeIntervalSince1970: 1_756_000_000),
                isAppDescendant: true
            )
        }
    #else
        /// Release stub: no substitution, so the real sweep always proceeds.
        static func fixtureAlerts(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> [RuntimeProcessAlert]? { nil }
    #endif
}
