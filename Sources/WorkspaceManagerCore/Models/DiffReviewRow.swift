//
//  DiffReviewRow.swift
//  WorkspaceManagerCore
//
//  Flat, render-ready row model for the native diff review surface. `DiffReviewRowBuilder`
//  turns a parsed `UnifiedDiff` into a sequence of hunk-header and line rows, each tagged
//  addition / removal / context and carrying the old/new line numbers a gutter shows. This
//  transform is pure so the view stays a thin renderer (see #704 Phase 3).
//

import Foundation

public struct DiffReviewRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case hunkHeader
        case addition
        case removal
        case context
    }

    /// Stable position in the flattened row list.
    public let id: Int
    public let kind: Kind
    public let content: String
    /// Line number in the old file (nil for additions and hunk headers).
    public let oldLineNumber: Int?
    /// Line number in the new file (nil for removals and hunk headers).
    public let newLineNumber: Int?

    public init(id: Int, kind: Kind, content: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.id = id
        self.kind = kind
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

public enum DiffReviewRowBuilder {
    /// Flatten `diff` into render rows, assigning per-side line numbers as the hunk advances.
    public static func rows(from diff: UnifiedDiff) -> [DiffReviewRow] {
        var rows: [DiffReviewRow] = []
        for hunk in diff.hunks {
            rows.append(
                DiffReviewRow(
                    id: rows.count,
                    kind: .hunkHeader,
                    content: hunkHeaderText(hunk),
                    oldLineNumber: nil,
                    newLineNumber: nil
                )
            )
            var oldLine = hunk.oldStart
            var newLine = hunk.newStart
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    rows.append(
                        DiffReviewRow(
                            id: rows.count, kind: .context, content: line.content,
                            oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                case .added:
                    rows.append(
                        DiffReviewRow(
                            id: rows.count, kind: .addition, content: line.content,
                            oldLineNumber: nil, newLineNumber: newLine))
                    newLine += 1
                case .removed:
                    rows.append(
                        DiffReviewRow(
                            id: rows.count, kind: .removal, content: line.content,
                            oldLineNumber: oldLine, newLineNumber: nil))
                    oldLine += 1
                }
            }
        }
        return rows
    }

    /// The `@@ -old,count +new,count @@` header line for a hunk.
    public static func hunkHeaderText(_ hunk: UnifiedDiff.Hunk) -> String {
        "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
    }
}
