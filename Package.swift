// swift-tools-version: 5.10
// ============================================================================
// WorkspaceManager - macOS Terminal-Based Workspace Manager
// ============================================================================
//
// This package defines the build configuration for WorkspaceManager, a native
// macOS app for managing AI coding session workspaces with integrated terminal.
//
// Structure:
// - WorkspaceManagerCore: Core library with models and services (reusable)
// - WorkspaceManager: Main executable with SwiftUI views and AppKit integration
// - WorkspaceManagerTests: Test suite for the core library
//
// Resources:
// - Resources/Info.plist: App bundle identity and configuration
// - Resources/PrivacyInfo.xcprivacy: Privacy manifest (required for notarization)
// - Resources/Assets.xcassets: App icon and other assets
//
// Build Commands:
// - Debug:   swift build
// - Release: swift build -c release
// - Test:    swift test
// - Bundle:  ./scripts/build-release.sh (creates signed .app bundle)
//
// ============================================================================

import PackageDescription

let package = Package(
    name: "WorkspaceManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WorkspaceManager", targets: ["WorkspaceManager"]),
        .executable(name: "workspaces", targets: ["WorkspaceManagerCLI"]),
        .executable(name: "WorkspaceManagerCLI", targets: ["WorkspaceManagerCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: [
        // ====================================================================
        // Core Library
        // ====================================================================
        // Contains models and services that can be reused in other targets
        // or potentially shared with a CLI tool in the future.
        .target(
            name: "WorkspaceManagerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),

        // ====================================================================
        // Ghostty Binary
        // ====================================================================
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),

        // ====================================================================
        // Main Application
        // ====================================================================
        // SwiftUI app with AppKit integration for terminal windows.
        // Resources are bundled for the .app bundle creation.
        .executableTarget(
            name: "WorkspaceManager",
            dependencies: [
                "WorkspaceManagerCore",
                "GhosttyKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            // Exclude Info.plist from automatic resource discovery
            // (SPM forbids Info.plist as a bundled resource; it's copied by build-release.sh)
            exclude: ["Resources/Info.plist"],
            resources: [
                // Privacy manifest (required for macOS 14+ notarization)
                .copy("Resources/PrivacyInfo.xcprivacy"),

                // App icons and assets
                .process("Resources/Assets.xcassets"),

                // Claude Code hook forwarders — bundled .sh files for hook
                // events and status-line forwarding.
                // The installer wires them into ~/.claude/settings.json by
                // absolute path, extracting them to a writable path on opt-in
                // install when needed.
                .copy("Resources/HookForwarders"),

                // Embedded CodeMirror diff/editor bundle (built by scripts/build-editor-web.sh).
                .copy("Resources/DiffEditorWeb")
            ],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit"),
                .unsafeFlags([
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "@executable_path/../Frameworks"
                ])
            ]
        ),

        // ====================================================================
        // CLI Application
        // ====================================================================
        // Lightweight terminal-first interface for daily workspace workflows.
        .executableTarget(
            name: "WorkspaceManagerCLI",
            dependencies: ["WorkspaceManagerCore"],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),

        // ====================================================================
        // Tests
        // ====================================================================
        .testTarget(
            name: "WorkspaceManagerTests",
            dependencies: [
                "WorkspaceManagerCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "WorkspaceManagerAppTests",
            dependencies: ["WorkspaceManager"]
        )
    ]
)
