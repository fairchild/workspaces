import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("DiffReviewRowBuilder")
struct DiffReviewRowBuilderTests {
    private func sampleDiff() -> UnifiedDiff {
        // @@ -1,3 +1,4 @@ : context, remove, add, add, context
        UnifiedDiff(
            path: "src/app.swift",
            hunks: [
                UnifiedDiff.Hunk(
                    oldStart: 1, oldCount: 3, newStart: 1, newCount: 4,
                    lines: [
                        UnifiedDiff.Line(kind: .context, content: "let a = 1"),
                        UnifiedDiff.Line(kind: .removed, content: "let b = 2"),
                        UnifiedDiff.Line(kind: .added, content: "let b = 3"),
                        UnifiedDiff.Line(kind: .added, content: "let c = 4"),
                        UnifiedDiff.Line(kind: .context, content: "return a"),
                    ]
                )
            ]
        )
    }

    @Test("A hunk becomes a header row followed by its line rows in order")
    func flattensHunkWithHeader() {
        let rows = DiffReviewRowBuilder.rows(from: sampleDiff())
        #expect(rows.count == 6)
        #expect(rows[0].kind == .hunkHeader)
        #expect(rows[0].content == "@@ -1,3 +1,4 @@")
        #expect(rows.map(\.kind) == [.hunkHeader, .context, .removal, .addition, .addition, .context])
        // Ids are the stable flattened positions.
        #expect(rows.map(\.id) == [0, 1, 2, 3, 4, 5])
    }

    @Test("Removals carry only an old line number; additions carry only a new line number")
    func lineNumbersMatchSide() {
        let rows = DiffReviewRowBuilder.rows(from: sampleDiff())
        let context1 = rows[1]
        #expect(context1.kind == .context)
        #expect(context1.oldLineNumber == 1 && context1.newLineNumber == 1)

        let removal = rows[2]
        #expect(removal.kind == .removal)
        #expect(removal.oldLineNumber == 2 && removal.newLineNumber == nil)

        let addition = rows[3]
        #expect(addition.kind == .addition)
        #expect(addition.oldLineNumber == nil && addition.newLineNumber == 2)

        // After one removal + two additions, the trailing context advances both sides.
        let context2 = rows[5]
        #expect(context2.oldLineNumber == 3 && context2.newLineNumber == 4)
    }

    @Test("An empty diff produces no rows")
    func emptyDiffHasNoRows() {
        #expect(DiffReviewRowBuilder.rows(from: UnifiedDiff(path: "x", hunks: [])).isEmpty)
    }
}
