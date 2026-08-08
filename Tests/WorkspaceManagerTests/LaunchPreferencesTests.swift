// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures force-unwrap a suite name this test just minted; a failure here is a loud test crash.
//
//  LaunchPreferencesTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("LaunchPreferences")
struct LaunchPreferencesTests {
    private func scratchSuiteName() -> String {
        "com.cloudcompute.workspaces.tests.\(UUID().uuidString)"
    }

    // MARK: Resolution

    @Test("An unmarked environment resolves to the persistent domain")
    func plainEnvironmentIsStandard() {
        #expect(LaunchPreferencesEnvironment.resolution(environment: [:]) == .standard)
        #expect(
            LaunchPreferencesEnvironment.resolution(
                environment: ["WORKSPACES_DATA_DIR": "/tmp/data"]
            ) == .standard
        )
    }

    @Test("A synthetic root routes to that root's scratch suite and claims the reset")
    func syntheticRootIsolates() {
        let resolution = LaunchPreferencesEnvironment.resolution(
            environment: [LaunchPreferencesEnvironment.syntheticRootKey: "/tmp/synthetic-root"]
        )

        #expect(
            resolution
                == .scratch(
                    suiteName: LaunchPreferencesEnvironment.scratchSuiteName(
                        forSyntheticRoot: "/tmp/synthetic-root"
                    ),
                    resetOnLaunch: true
                )
        )
        #expect(resolution.isIsolated)
        #expect(resolution.resetsOnLaunch)
    }

    @Test("Each synthetic root gets its own suite, so concurrent isolated launches cannot collide")
    func syntheticRootsGetDistinctSuites() {
        let first = LaunchPreferencesEnvironment.scratchSuiteName(forSyntheticRoot: "/tmp/root-a")
        let second = LaunchPreferencesEnvironment.scratchSuiteName(forSyntheticRoot: "/tmp/root-b")

        #expect(first != second)
        #expect(first.hasPrefix(LaunchPreferencesEnvironment.scratchSuiteBaseName + "."))
        #expect(second.hasPrefix(LaunchPreferencesEnvironment.scratchSuiteBaseName + "."))
    }

    @Test("One root names one suite across processes, so a helper joins the app's suite")
    func syntheticRootSuiteIsStableAcrossProcesses() {
        // Derived, not random: the value has to be reproducible by a separately
        // launched process (the `workspaces` CLI driving a live isolated app), not
        // just within this one — which rules out `Hasher`.
        #expect(
            LaunchPreferencesEnvironment.scratchSuiteName(forSyntheticRoot: "/tmp/root-a")
                == LaunchPreferencesEnvironment.scratchSuiteName(forSyntheticRoot: "/tmp/root-a")
        )
        #expect(
            LaunchPreferencesEnvironment.scratchSuiteName(forSyntheticRoot: "/tmp/synthetic-root")
                == "com.cloudcompute.workspaces.isolated.cc2195059e870052"
        )
    }

    @Test("A blank synthetic root is not an isolation signal")
    func blankSyntheticRootIsStandard() {
        let resolution = LaunchPreferencesEnvironment.resolution(
            environment: [LaunchPreferencesEnvironment.syntheticRootKey: "   "]
        )

        #expect(resolution == .standard)
        #expect(!resolution.isIsolated)
    }

    @Test("An explicit suite wins over the synthetic root and keeps its own lifetime")
    func explicitSuiteWins() {
        let resolution = LaunchPreferencesEnvironment.resolution(
            environment: [
                LaunchPreferencesEnvironment.suiteOverrideKey: " probe-suite ",
                LaunchPreferencesEnvironment.syntheticRootKey: "/tmp/synthetic-root",
            ]
        )

        #expect(resolution == .scratch(suiteName: "probe-suite", resetOnLaunch: false))
        #expect(!resolution.resetsOnLaunch)
    }

    @Test("A reserved suite name is ignored rather than allowed to defeat isolation")
    func reservedSuiteNameFallsThrough() {
        for reserved in LaunchPreferencesEnvironment.reservedSuiteNames {
            let stillIsolated = LaunchPreferencesEnvironment.resolution(
                environment: [
                    LaunchPreferencesEnvironment.suiteOverrideKey: reserved,
                    LaunchPreferencesEnvironment.syntheticRootKey: "/tmp/synthetic-root",
                ]
            )
            #expect(
                stillIsolated
                    == .scratch(
                        suiteName: LaunchPreferencesEnvironment.scratchSuiteName(
                            forSyntheticRoot: "/tmp/synthetic-root"
                        ),
                        resetOnLaunch: true
                    )
            )

            let noOtherSignal = LaunchPreferencesEnvironment.resolution(
                environment: [LaunchPreferencesEnvironment.suiteOverrideKey: reserved]
            )
            #expect(noOtherSignal == .standard)
        }
    }

    @Test("The scratch-suite base name is reserved, so the escape hatch cannot alias it")
    func scratchSuiteBaseNameIsReserved() {
        #expect(
            LaunchPreferencesEnvironment.reservedSuiteNames
                .contains(LaunchPreferencesEnvironment.scratchSuiteBaseName)
        )
        #expect(
            LaunchPreferencesEnvironment.resolution(
                environment: [
                    LaunchPreferencesEnvironment.suiteOverrideKey:
                        LaunchPreferencesEnvironment.scratchSuiteBaseName
                ]
            ) == .standard
        )
    }

    // MARK: Bootstrap

    @Test("Bootstrap wipes a scratch suite whose resolution claims the reset")
    func bootstrapWipesTheSuiteItOwns() {
        let suiteName = scratchSuiteName()
        defer { LaunchPreferences.reset(suiteName: suiteName) }
        let key = "mainWindow.lastSurface"

        let store = UserDefaults(suiteName: suiteName)!
        store.set("stale-surface", forKey: key)

        LaunchPreferences.bootstrap(resolution: .scratch(suiteName: suiteName, resetOnLaunch: true))

        #expect(store.string(forKey: key) == nil)
    }

    @Test("Bootstrap never wipes a suite the caller named explicitly")
    func bootstrapPreservesAnExplicitlyNamedSuite() {
        let suiteName = scratchSuiteName()
        defer { LaunchPreferences.reset(suiteName: suiteName) }
        let key = "mainWindow.lastSurface"

        let store = UserDefaults(suiteName: suiteName)!
        store.set("caller-owned-surface", forKey: key)

        let resolution = LaunchPreferencesEnvironment.resolution(
            environment: [LaunchPreferencesEnvironment.suiteOverrideKey: suiteName]
        )
        #expect(resolution == .scratch(suiteName: suiteName, resetOnLaunch: false))

        LaunchPreferences.bootstrap(resolution: resolution)

        #expect(store.string(forKey: key) == "caller-owned-surface")
    }

    // MARK: Store construction

    @Test("The standard resolution hands back the persistent domain")
    func standardResolutionUsesStandardDefaults() {
        #expect(LaunchPreferences.makeDefaults(for: .standard) === UserDefaults.standard)
    }

    @Test("A scratch resolution reads and writes outside the persistent domain")
    func scratchResolutionIsolatesWrites() {
        let suiteName = scratchSuiteName()
        defer { LaunchPreferences.reset(suiteName: suiteName) }
        let key = "mainWindow.lastSurface"

        let scratch = LaunchPreferences.makeDefaults(for: .scratch(suiteName: suiteName, resetOnLaunch: true))
        #expect(scratch !== UserDefaults.standard)

        scratch.set("isolated-surface", forKey: key)
        #expect(scratch.string(forKey: key) == "isolated-surface")
        #expect(UserDefaults.standard.persistentDomain(forName: suiteName)?[key] != nil)
    }

    @Test("Building the store does not clear the suite — only an explicit reset does")
    func storeConstructionPreservesExistingValues() {
        let suiteName = scratchSuiteName()
        defer { LaunchPreferences.reset(suiteName: suiteName) }
        let key = "mainWindow.lastSurface"

        let seeded = UserDefaults(suiteName: suiteName)!
        seeded.set("stale-surface", forKey: key)

        let resolution = LaunchPreferencesResolution.scratch(suiteName: suiteName, resetOnLaunch: true)
        #expect(LaunchPreferences.makeDefaults(for: resolution).string(forKey: key) == "stale-surface")

        LaunchPreferences.reset(suiteName: suiteName)
        #expect(LaunchPreferences.makeDefaults(for: resolution).string(forKey: key) == nil)
    }

    @Test("A reset clears values a previously vended store can still see")
    func resetClearsAlreadyVendedStore() {
        let suiteName = scratchSuiteName()
        defer { LaunchPreferences.reset(suiteName: suiteName) }
        let key = "mainWindow.lastSurface"

        let store = LaunchPreferences.makeDefaults(for: .scratch(suiteName: suiteName, resetOnLaunch: true))
        store.set("stale-surface", forKey: key)
        #expect(store.string(forKey: key) == "stale-surface")

        LaunchPreferences.reset(suiteName: suiteName)
        #expect(store.string(forKey: key) == nil)
    }
}
