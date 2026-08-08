//
//  MainWindowPathResolutionTests.swift
//  WorkspaceManagerAppTests
//
//  The containment and launch-directory rules the main window's selection paths depend on:
//  an unvalidated restored or deep-linked directory must never open outside its root.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("MainWindowPathResolution")
struct MainWindowPathResolutionTests {
    private func makeDirectory(_ components: String...) throws -> URL {
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-resolution-\(UUID().uuidString)", isDirectory: true)
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @Test("A path is inside itself and inside its ancestors, but a sibling prefix is not")
    func containmentRejectsSiblingPrefixes() {
        #expect(MainWindowPathResolution.path("/a/b", isInside: "/a/b"))
        #expect(MainWindowPathResolution.path("/a/b/c", isInside: "/a/b"))
        #expect(!MainWindowPathResolution.path("/a/bc", isInside: "/a/b"))
        #expect(!MainWindowPathResolution.path("/a", isInside: "/a/b"))
    }

    @Test("Everything is inside the filesystem root")
    func rootContainsEverything() {
        #expect(MainWindowPathResolution.path("/anywhere/at/all", isInside: "/"))
    }

    @Test("No preferred directory launches at the root")
    func missingPreferredDirectoryUsesRoot() throws {
        let root = try makeDirectory("repo")

        #expect(MainWindowPathResolution.preferredSessionDirectory(nil, inside: root) == root)
    }

    @Test("An existing subdirectory of the root becomes the launch directory")
    func nestedDirectoryIsHonoured() throws {
        let root = try makeDirectory("repo")
        let nested = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(MainWindowPathResolution.preferredSessionDirectory(nested, inside: root) == nested)
    }

    @Test("A directory outside the root falls back to the root")
    func escapedDirectoryFallsBackToRoot() throws {
        let root = try makeDirectory("repo")
        let outside = try makeDirectory("elsewhere")

        #expect(MainWindowPathResolution.preferredSessionDirectory(outside, inside: root) == root)
    }

    @Test("A stale directory that no longer exists falls back to the root")
    func missingDirectoryFallsBackToRoot() throws {
        let root = try makeDirectory("repo")
        let stale = root.appendingPathComponent("gone", isDirectory: true)

        #expect(MainWindowPathResolution.preferredSessionDirectory(stale, inside: root) == root)
    }

    @Test("A file inside the root is not a launch directory")
    func fileFallsBackToRoot() throws {
        let root = try makeDirectory("repo")
        let file = root.appendingPathComponent("README.md")
        try Data("hello".utf8).write(to: file)

        #expect(MainWindowPathResolution.preferredSessionDirectory(file, inside: root) == root)
    }
}
