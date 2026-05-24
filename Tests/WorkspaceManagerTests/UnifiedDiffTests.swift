//
//  UnifiedDiffTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("UnifiedDiff")
struct UnifiedDiffTests {

    @Test("Parses single-hunk modification")
    func parsesSingleHunkModification() throws {
        let raw = """
            diff --git a/file.txt b/file.txt
            index 1234567..89abcde 100644
            --- a/file.txt
            +++ b/file.txt
            @@ -1,3 +1,3 @@
             line1
            -old
            +new
             line3
            """
        let diff = try UnifiedDiff.parse(raw, path: "file.txt")
        #expect(diff.path == "file.txt")
        #expect(diff.oldPath == nil)
        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 3)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 3)
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[0] == .init(kind: .context, content: "line1"))
        #expect(hunk.lines[1] == .init(kind: .removed, content: "old"))
        #expect(hunk.lines[2] == .init(kind: .added, content: "new"))
        #expect(hunk.lines[3] == .init(kind: .context, content: "line3"))
    }

    @Test("Parses added file")
    func parsesAddedFile() throws {
        let raw = """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..abcdef0
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1,2 @@
            +alpha
            +beta
            """
        let diff = try UnifiedDiff.parse(raw, path: "new.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 2)
        #expect(diff.removedLines == 0)
        #expect(diff.hunks[0].oldStart == 0)
        #expect(diff.hunks[0].oldCount == 0)
        #expect(diff.hunks[0].newStart == 1)
        #expect(diff.hunks[0].newCount == 2)
    }

    @Test("Parses removed file")
    func parsesRemovedFile() throws {
        let raw = """
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index abcdef0..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -alpha
            -beta
            """
        let diff = try UnifiedDiff.parse(raw, path: "gone.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.removedLines == 2)
        #expect(diff.addedLines == 0)
        #expect(diff.hunks[0].newStart == 0)
        #expect(diff.hunks[0].newCount == 0)
    }

    @Test("Parses multiple hunks")
    func parsesMultipleHunks() throws {
        let raw = """
            diff --git a/big.txt b/big.txt
            index 1111111..2222222 100644
            --- a/big.txt
            +++ b/big.txt
            @@ -1,3 +1,3 @@
             a
            -b
            +B
             c
            @@ -10,3 +10,4 @@
             x
             y
            +Y
             z
            """
        let diff = try UnifiedDiff.parse(raw, path: "big.txt")
        #expect(diff.hunks.count == 2)
        #expect(diff.addedLines == 2)
        #expect(diff.removedLines == 1)
        #expect(diff.hunks[0].oldStart == 1)
        #expect(diff.hunks[1].oldStart == 10)
        #expect(diff.hunks[1].newCount == 4)
    }

    @Test("Parses rename and captures oldPath")
    func parsesRename() throws {
        let raw = """
            diff --git a/old.txt b/new.txt
            similarity index 90%
            rename from old.txt
            rename to new.txt
            index 1111111..2222222 100644
            --- a/old.txt
            +++ b/new.txt
            @@ -1,2 +1,2 @@
             keep
            -was
            +is
            """
        let diff = try UnifiedDiff.parse(raw, path: "new.txt")
        #expect(diff.oldPath == "old.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
    }

    @Test("Single-line hunk default count is 1")
    func singleLineHunkDefaultCount() throws {
        let raw = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -5 +5 @@
            -old
            +new
            """
        let diff = try UnifiedDiff.parse(raw, path: "f.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].oldStart == 5)
        #expect(diff.hunks[0].oldCount == 1)
        #expect(diff.hunks[0].newStart == 5)
        #expect(diff.hunks[0].newCount == 1)
    }

    @Test("Empty diff produces no hunks")
    func emptyDiffProducesNoHunks() throws {
        let diff = try UnifiedDiff.parse("", path: "file.txt")
        #expect(diff.hunks.isEmpty)
        #expect(diff.addedLines == 0)
        #expect(diff.removedLines == 0)
    }

    @Test("Ignores no-newline marker")
    func ignoresNoNewlineMarker() throws {
        let raw = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1 +1 @@
            -hello
            \\ No newline at end of file
            +hello!
            \\ No newline at end of file
            """
        let diff = try UnifiedDiff.parse(raw, path: "f.txt")
        #expect(diff.hunks.count == 1)
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
    }
}
