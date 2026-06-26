//
//  GhosttyScrollStateTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyScrollPositionMapper")
struct GhosttyScrollPositionMapperTests {
    @Test("document height scales terminal rows into scroll view pixels")
    func documentHeightScalesRows() {
        let state = GhosttyScrollbarState(total: 120, offset: 96, length: 24)

        #expect(
            GhosttyScrollPositionMapper.documentHeight(contentHeight: 480, state: state)
                == 2400
        )
    }

    @Test("terminal offset maps to AppKit bottom-origin content offset")
    func terminalOffsetMapsToAppKitOffset() {
        let state = GhosttyScrollbarState(total: 120, offset: 80, length: 24)

        #expect(
            GhosttyScrollPositionMapper.contentOffsetY(contentHeight: 480, state: state)
                == 320
        )
    }

    @Test("scroll view visible rect maps back to a terminal row")
    func visibleRectMapsBackToTerminalRow() throws {
        let state = GhosttyScrollbarState(total: 120, offset: 80, length: 24)
        let row = try #require(
            GhosttyScrollPositionMapper.row(
                visibleRect: CGRect(x: 0, y: 320, width: 800, height: 480),
                documentHeight: 2400,
                contentHeight: 480,
                state: state
            ))

        #expect(row == 80)
    }
}
