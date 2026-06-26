//
//  GhosttyScrollState.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

struct GhosttyScrollbarState: Equatable, Sendable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64

    init(total: UInt64, offset: UInt64, length: UInt64) {
        self.total = total
        self.offset = offset
        self.length = length
    }

    init(_ action: ghostty_action_scrollbar_s) {
        self.init(total: action.total, offset: action.offset, length: action.len)
    }

    var maxOffset: UInt64 {
        total > length ? total - length : 0
    }
}

enum GhosttyScrollPositionMapper {
    static func rowHeight(contentHeight: CGFloat, visibleRows: UInt64) -> CGFloat? {
        guard contentHeight > 0, visibleRows > 0 else { return nil }
        return contentHeight / CGFloat(visibleRows)
    }

    static func documentHeight(contentHeight: CGFloat, state: GhosttyScrollbarState?) -> CGFloat {
        guard
            let state,
            let rowHeight = rowHeight(contentHeight: contentHeight, visibleRows: state.length)
        else {
            return max(contentHeight, 0)
        }

        return max(contentHeight, CGFloat(state.total) * rowHeight)
    }

    static func contentOffsetY(contentHeight: CGFloat, state: GhosttyScrollbarState) -> CGFloat {
        guard let rowHeight = rowHeight(contentHeight: contentHeight, visibleRows: state.length) else {
            return 0
        }

        let offsetFromBottom = state.maxOffset - min(state.offset, state.maxOffset)
        return CGFloat(offsetFromBottom) * rowHeight
    }

    static func row(
        visibleRect: CGRect,
        documentHeight: CGFloat,
        contentHeight: CGFloat,
        state: GhosttyScrollbarState?
    ) -> Int? {
        guard
            let state,
            let rowHeight = rowHeight(contentHeight: contentHeight, visibleRows: state.length),
            rowHeight > 0
        else {
            return nil
        }

        let offsetFromTop = max(0, documentHeight - visibleRect.origin.y - visibleRect.height)
        let rawRow = UInt64(max(0, round(offsetFromTop / rowHeight)))
        return Int(min(rawRow, state.maxOffset))
    }
}

enum GhosttyScrollInput {
    static func mods(from event: NSEvent) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            value |= 0b0000_0001
        }
        value |= Int32(momentumRawValue(from: event.momentumPhase)) << 1
        return ghostty_input_scroll_mods_t(value)
    }

    private static func momentumRawValue(from phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            return UInt8(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
    }
}
