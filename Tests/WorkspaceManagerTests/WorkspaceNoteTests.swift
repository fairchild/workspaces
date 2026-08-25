//
//  WorkspaceNoteTests.swift
//  WorkspaceManagerTests
//
//  Normalization is what lets the sidebar render a note without defending itself, so
//  the properties pinned here are the ones the row depends on: one line, bounded, and
//  "cleared" indistinguishable from "never set".
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WorkspaceNote")
struct WorkspaceNoteTests {

    @Test("Empty, whitespace-only, and absent all normalize to no note")
    func emptyInputsClear() {
        #expect(WorkspaceNote.normalized(nil) == nil)
        #expect(WorkspaceNote.normalized("") == nil)
        #expect(WorkspaceNote.normalized("   \n\t ") == nil)
    }

    @Test("Surrounding whitespace goes and interior breaks collapse to single spaces")
    func collapsesToOneLine() {
        #expect(WorkspaceNote.normalized("  rebasing  onto main  ") == "rebasing onto main")
        #expect(WorkspaceNote.normalized("line one\nline two") == "line one line two")
        #expect(WorkspaceNote.normalized("tabs\there\ttoo") == "tabs here too")
        #expect(WorkspaceNote.normalized("a\n\n\nb") == "a b")
    }

    @Test("A note longer than the bound is truncated with an ellipsis, at the bound")
    func truncatesAtBound() throws {
        let long = String(repeating: "x", count: WorkspaceNote.maxLength + 40)
        let normalized = try #require(WorkspaceNote.normalized(long))

        #expect(normalized.count == WorkspaceNote.maxLength)
        #expect(normalized.hasSuffix("…"))
    }

    @Test("A note exactly at the bound is kept whole")
    func boundaryNoteIsUntouched() {
        let exact = String(repeating: "y", count: WorkspaceNote.maxLength)
        #expect(WorkspaceNote.normalized(exact) == exact)
    }

    @Test("Normalizing an already-normal note changes nothing")
    func idempotent() {
        let once = WorkspaceNote.normalized("  handed off to review  ")
        #expect(WorkspaceNote.normalized(once) == once)
    }
}
