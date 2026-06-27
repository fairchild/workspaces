//
//  GhosttyDroppedContentFormatterTests.swift
//  WorkspaceManagerAppTests
//

import AppKit
import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyDroppedContentFormatter")
struct GhosttyDroppedContentFormatterTests {
    @Test("Accepts string, file URL, and URL pasteboard types")
    func acceptsRegisteredPasteboardTypes() {
        #expect(GhosttyDroppedContentFormatter.accepts(types: [.string]))
        #expect(GhosttyDroppedContentFormatter.accepts(types: [.fileURL]))
        #expect(GhosttyDroppedContentFormatter.accepts(types: [.URL]))
        #expect(!GhosttyDroppedContentFormatter.accepts(types: [.png]))
        #expect(!GhosttyDroppedContentFormatter.accepts(types: nil))
    }

    @Test("Escapes shell-sensitive characters in dropped file paths")
    func escapesShellSensitiveCharacters() {
        let path = #"/Users/fairchild/My Files/[draft] "quote" and 'apostrophe'?.md"#

        #expect(
            GhosttyDroppedContentFormatter.shellEscape(path)
                == #"/Users/fairchild/My\ Files/\[draft\]\ \"quote\"\ and\ \'apostrophe\'\?.md"#
        )
    }

    @Test("Joins multiple file URLs with escaped paths")
    func joinsMultipleFileURLs() {
        let content = GhosttyDroppedContentFormatter.content(forURLs: [
            URL(fileURLWithPath: "/tmp/My File.txt"),
            URL(fileURLWithPath: "/tmp/query?.swift"),
        ])

        #expect(content == #"/tmp/My\ File.txt /tmp/query\?.swift"#)
    }

    @Test("Returns nil for an empty file URL list")
    func emptyFileURLListReturnsNil() {
        #expect(GhosttyDroppedContentFormatter.content(forURLs: []) == nil)
    }

    @Test("Keeps non-file URL objects intact")
    func keepsNonFileURLObjectsIntact() throws {
        let url = try #require(URL(string: "https://example.com/a b?q=1&x=2"))

        #expect(GhosttyDroppedContentFormatter.content(forURLs: [url]) == #"https://example.com/a%20b\?q=1\&x=2"#)
    }

    @Test("Keeps plain strings unescaped")
    func keepsPlainStringsUnescaped() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspaces-drop-string-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("echo 'already quoted' && ls ~/Desktop", forType: .string)

        #expect(GhosttyDroppedContentFormatter.content(from: pasteboard) == "echo 'already quoted' && ls ~/Desktop")
    }

    @Test("Escapes URL pasteboard strings before insertion")
    func escapesURLPasteboardStrings() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspaces-drop-url-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/a b?q=1&x=2", forType: .URL)

        #expect(GhosttyDroppedContentFormatter.content(from: pasteboard) == #"https://example.com/a\ b\?q=1\&x=2"#)
    }
}
