// swift-tools-version: 6.0
// Terminal emulation for the mobile variant, on libghostty-vt 1.0. The
// library arrives as Ghostty's signed release xcframework, pinned by URL and
// checksum so SwiftPM verifies every download. Kept out of the root
// Package.swift: the desktop app links GhosttyKit, whose static Zig runtime
// collides with this one (docs/development/libghostty-vt.md).
import PackageDescription

let package = Package(
    name: "TerminalScreen",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TerminalScreen", targets: ["TerminalScreen"])
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.0/ghostty-vt-1.0.0.xcframework.zip",
            checksum: "2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2"
        ),
        .target(
            name: "TerminalScreen",
            dependencies: ["GhosttyVt"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(
            name: "TerminalScreenTests",
            dependencies: ["TerminalScreen"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
