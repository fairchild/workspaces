//
//  ModelsTests.swift
//  WorkspaceManagerTests
//
//  Tests for model behavior: identity, equality, serialization contracts
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Models")
struct ModelsTests {

    // MARK: - FileChange Tests

    @Suite("FileChange")
    struct FileChangeTests {
        @Test("Same path produces same identity regardless of status")
        func identityBasedOnPath() {
            let modified = FileChange(path: "src/main.swift", status: .modified)
            let added = FileChange(path: "src/main.swift", status: .added)

            #expect(modified.id == added.id)
        }

        @Test("Deduplicates by path in a Set")
        func deduplicatesByPath() {
            let a = FileChange(path: "file.txt", status: .modified)
            let b = FileChange(path: "file.txt", status: .modified)
            let c = FileChange(path: "other.txt", status: .modified)

            let set = Set([a, b, c])
            #expect(set.count == 2)
        }

        @Test("Different statuses for same path are not equal")
        func statusAffectsEquality() {
            let modified = FileChange(path: "file.txt", status: .modified)
            let added = FileChange(path: "file.txt", status: .added)

            #expect(modified != added)
        }
    }

    // MARK: - GitStatus Tests

    @Suite("GitStatus")
    struct GitStatusTests {
        @Test("Raw values match git porcelain format")
        func rawValuesMatchGitPorcelain() {
            #expect(GitStatus.modified.rawValue == "M")
            #expect(GitStatus.added.rawValue == "A")
            #expect(GitStatus.deleted.rawValue == "D")
            #expect(GitStatus.untracked.rawValue == "?")
            #expect(GitStatus.renamed.rawValue == "R")
        }
    }

    // MARK: - WorkspaceStatus Tests

    @Suite("WorkspaceStatus")
    struct WorkspaceStatusTests {
        @Test("Survives Codable roundtrip")
        func codableRoundtrip() throws {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()

            for status in WorkspaceStatus.allCases {
                let data = try encoder.encode(status)
                let decoded = try decoder.decode(WorkspaceStatus.self, from: data)
                #expect(decoded == status)
            }
        }
    }

    // MARK: - FileNode Tests

    @Suite("FileNode")
    struct FileNodeTests {
        @Test("Equality based on path")
        func equalityBasedOnPath() {
            let a = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)
            let b = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)
            let c = FileNode(name: "file.txt", path: "other/file.txt", isDirectory: false, children: nil)

            #expect(a == b)
            #expect(a != c)
        }

        @Test("Deduplicates by path in a Set")
        func deduplicatesByPath() {
            let a = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)
            let b = FileNode(name: "file.txt", path: "src/file.txt", isDirectory: false, children: nil)

            let set = Set([a, b])
            #expect(set.count == 1)
        }
    }
}
