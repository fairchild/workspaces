// A headless terminal emulator on libghostty-vt: feed it the bytes a program
// writes, read back what a terminal would show. Owns every C handle it uses
// and frees them in deinit. Not Sendable — libghostty-vt handles are not
// thread-safe — so it lives on one actor and hands out Sendable snapshots.
import GhosttyVt

public struct TerminalError: Error, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public var description: String { "libghostty-vt \(operation) failed (\(code))" }
}

public final class VirtualTerminal {
    public private(set) var columns: Int
    public private(set) var rows: Int

    private let terminal: GhosttyTerminal
    private let renderState: GhosttyRenderState
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var graphemeBuffer = [UInt8](repeating: 0, count: 32)
    private var lastSnapshot: TerminalSnapshot?

    /// Throws for a geometry outside 1...65535 in either dimension, or when
    /// the library cannot allocate.
    public init(columns: Int, rows: Int) throws(TerminalError) {
        let (width, height) = try geometry(columns, rows, for: "terminal_new")
        var terminal: GhosttyTerminal?
        var renderState: GhosttyRenderState?
        var rowIterator: GhosttyRenderStateRowIterator?
        var rowCells: GhosttyRenderStateRowCells?
        do {
            try check("terminal_new", ghostty_terminal_new(nil, &terminal, width, height))
            try check("render_state_new", ghostty_render_state_new(nil, &renderState))
            try check("row_iterator_new", ghostty_render_state_row_iterator_new(nil, &rowIterator))
            try check("row_cells_new", ghostty_render_state_row_cells_new(nil, &rowCells))
        } catch {
            ghostty_render_state_row_cells_free(rowCells)
            ghostty_render_state_row_iterator_free(rowIterator)
            ghostty_render_state_free(renderState)
            ghostty_terminal_free(terminal)
            throw error
        }
        guard let terminal, let renderState else {
            throw TerminalError(operation: "terminal_new", code: GHOSTTY_OUT_OF_MEMORY.rawValue)
        }
        self.terminal = terminal
        self.renderState = renderState
        self.rowIterator = rowIterator
        self.rowCells = rowCells
        self.columns = columns
        self.rows = rows
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    /// The library version actually linked, which may be newer than the
    /// headers this package compiled against but never older.
    public static var libraryVersion: String { String(cString: ghostty_version()) }

    /// Never fails: malformed or partial sequences are absorbed, and an escape
    /// sequence split across two writes is completed by the second.
    public func write(_ bytes: some Collection<UInt8>) {
        let written = bytes.withContiguousStorageIfAvailable { buffer in
            ghostty_terminal_vt_write(terminal, buffer.baseAddress, buffer.count)
        }
        if written == nil {
            Array(bytes).withUnsafeBufferPointer { buffer in
                ghostty_terminal_vt_write(terminal, buffer.baseAddress, buffer.count)
            }
        }
    }

    public func write(_ text: String) {
        write(Array(text.utf8))
    }

    public func resize(columns: Int, rows: Int) throws(TerminalError) {
        let (width, height) = try geometry(columns, rows, for: "terminal_resize")
        try check("terminal_resize", ghostty_terminal_resize(terminal, width, height, 0, 0))
        self.columns = columns
        self.rows = rows
    }

    /// The current viewport. Cheap when nothing changed since the last call:
    /// a clean frame returns the cached snapshot without walking a single
    /// cell. The render state's dirty flag tracks rows only, so the cursor and
    /// default colors are compared separately — a bare cursor move or
    /// `ESC[?25l` changes no row.
    public func snapshot() throws(TerminalError) -> TerminalSnapshot {
        try check("render_state_update", ghostty_render_state_update(renderState, terminal))
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        let cursor = cursor()
        let foreground = renderColor(GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND)
        let background = renderColor(GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND)
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE, let lastSnapshot, lastSnapshot.cursor == cursor,
            lastSnapshot.foreground == foreground, lastSnapshot.background == background
        {
            return lastSnapshot
        }

        let snapshot = TerminalSnapshot(
            columns: columns,
            rows: rows,
            foreground: foreground,
            background: background,
            cursor: cursor,
            lines: try lines(cursor: cursor)
        )
        ghostty_render_state_clean(renderState)
        lastSnapshot = snapshot
        return snapshot
    }

    private func lines(cursor: TerminalCursor?) throws(TerminalError) -> [TerminalLine] {
        try check(
            "render_state_get(row_iterator)",
            ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        )
        var lines: [TerminalLine] = []
        lines.reserveCapacity(rows)
        while ghostty_render_state_row_iterator_next(rowIterator) {
            try check(
                "row_get(cells)",
                ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
            )
            let cursorColumn = cursor?.row == lines.count ? cursor?.column : nil
            var runs = RunBuilder()
            var column = 0
            while ghostty_render_state_row_cells_next(rowCells) {
                defer { column += 1 }
                let isCursor = column == cursorColumn
                switch cell() {
                case .text(let text, let width):
                    runs.append(text, width: width, style: cellStyle(), isCursor: isCursor)
                case .spacerTail where isCursor:
                    runs.markLastCursor()
                case .spacerHead where isCursor:
                    runs.append(" ", style: cellStyle(), isCursor: true)
                case .spacerTail, .spacerHead:
                    break
                }
            }
            lines.append(TerminalLine(runs: runs.finish()))
        }
        return lines
    }

    /// What one grid cell holds. A wide character is its `.text` cell (width
    /// 2) plus a `.spacerTail`; a wide character that wrapped leaves a
    /// `.spacerHead` in the last column of the line it left.
    private enum Cell {
        case text(String, width: Int)
        case spacerTail
        case spacerHead
    }

    /// An unwritten cell reads as a single space.
    private func cell() -> Cell {
        var raw: GhosttyCell = 0
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { return .spacerTail }
        if wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { return .spacerHead }
        let width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1

        while true {
            let (result, length) = graphemeBuffer.withUnsafeMutableBufferPointer { storage in
                var buffer = GhosttyBuffer(ptr: storage.baseAddress, cap: storage.count, len: 0)
                let result = ghostty_render_state_row_cells_get(
                    rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer
                )
                return (result, buffer.len)
            }
            if result == GHOSTTY_OUT_OF_SPACE {
                graphemeBuffer = [UInt8](repeating: 0, count: max(length, graphemeBuffer.count * 2))
                continue
            }
            guard result == GHOSTTY_SUCCESS, length > 0 else { return .text(" ", width: width) }
            return .text(String(decoding: graphemeBuffer[..<length], as: UTF8.self), width: width)
        }
    }

    private func cellStyle() -> CellStyle {
        var hasStyling = false
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
        var style = CellStyle(
            foreground: cellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR),
            background: cellColor(GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR)
        )
        guard hasStyling else { return style }

        var raw = GhosttyStyle()
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &raw)
        let flags = StyleFlags(rawValue: raw.flags)
        style.bold = flags.contains(.bold)
        style.italic = flags.contains(.italic)
        style.faint = flags.contains(.faint)
        style.inverse = flags.contains(.inverse)
        style.invisible = flags.contains(.invisible)
        style.strikethrough = flags.contains(.strikethrough)
        style.underline = flags.underline
        return style
    }

    /// Resolved through the palette by the library; nil means "the default".
    private func cellColor(_ key: GhosttyRenderStateRowCellsData) -> RGB? {
        var color = GhosttyColorRgb()
        guard ghostty_render_state_row_cells_get(rowCells, key, &color) == GHOSTTY_SUCCESS else { return nil }
        return RGB(color.r, color.g, color.b)
    }

    private func renderColor(_ key: GhosttyRenderStateData) -> RGB {
        var color = GhosttyColorRgb()
        ghostty_render_state_get(renderState, key, &color)
        return RGB(color.r, color.g, color.b)
    }

    private func cursor() -> TerminalCursor? {
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS,
            cursor.visible, cursor.viewport_has_value
        else { return nil }
        return TerminalCursor(column: Int(cursor.viewport_x), row: Int(cursor.viewport_y))
    }
}

/// `GhosttyStyleFlags` bit layout, frozen by the 1.0 ABI: bits 0–7 are
/// on/off attributes, bits 8–10 the underline style (0 = none). Spelled out
/// here because the header's cast-bearing macros do not import into Swift.
struct StyleFlags: OptionSet {
    let rawValue: GhosttyStyleFlags

    static let bold = StyleFlags(rawValue: 1 << 0)
    static let italic = StyleFlags(rawValue: 1 << 1)
    static let faint = StyleFlags(rawValue: 1 << 2)
    static let inverse = StyleFlags(rawValue: 1 << 4)
    static let invisible = StyleFlags(rawValue: 1 << 5)
    static let strikethrough = StyleFlags(rawValue: 1 << 6)

    var underline: Bool { (rawValue >> 8) & 0b111 != 0 }
}

/// Coalesces a row's cells into runs and drops trailing blanks that would
/// draw nothing, so a mostly-empty 80-column row costs one short run. Only
/// narrow cells merge, and only when each stays exactly one Character after
/// joining — Swift would fuse "©\u{200D}" and "®" from two cells into one,
/// and a cell the terminal clustered may hold several — which keeps
/// TextRun's one-Character-per-cell invariant for multi-cell runs. The cursor
/// cell never merges and is never trimmed.
struct RunBuilder {
    private var runs: [TextRun] = []

    mutating func append(_ text: String, width: Int = 1, style: CellStyle, isCursor: Bool = false) {
        if width == 1, !isCursor, text.count == 1, let last = runs.indices.last, runs[last].mergesNarrow(style) {
            let merged = runs[last].text + text
            if merged.count == runs[last].cells + 1 {
                runs[last].text = merged
                runs[last].columns += 1
                runs[last].cells += 1
                return
            }
        }
        runs.append(TextRun(text, style: style, isCursor: isCursor, columns: width, cells: 1))
    }

    /// The cursor sits on the right half of the wide character just appended,
    /// so that whole character is the cursor cell. Wide runs never merge, so
    /// the last run is exactly that character.
    mutating func markLastCursor() {
        guard let last = runs.indices.last, runs[last].cells == 1, runs[last].columns == 2 else { return }
        runs[last].isCursor = true
    }

    consuming func finish() -> [TextRun] {
        while let last = runs.last, !last.isCursor, !last.style.paintsBlank {
            let blanks = last.text.reversed().prefix(while: { $0 == " " }).count
            guard blanks > 0 else { break }
            if blanks == last.text.count {
                runs.removeLast()
                continue
            }
            guard last.cells > 1 else { break }
            runs[runs.count - 1].text.removeLast(blanks)
            runs[runs.count - 1].columns -= blanks
            runs[runs.count - 1].cells -= blanks
            break
        }
        return runs
    }
}

extension TextRun {
    fileprivate func mergesNarrow(_ style: CellStyle) -> Bool {
        !isCursor && columns == cells && text.count == cells && self.style == style
    }
}

private func geometry(_ columns: Int, _ rows: Int, for operation: String) throws(TerminalError) -> (UInt16, UInt16) {
    guard let width = UInt16(exactly: columns), let height = UInt16(exactly: rows), width > 0, height > 0 else {
        throw TerminalError(operation: operation, code: GHOSTTY_INVALID_VALUE.rawValue)
    }
    return (width, height)
}

private func check(_ operation: String, _ result: GhosttyResult) throws(TerminalError) {
    guard result == GHOSTTY_SUCCESS else {
        throw TerminalError(operation: operation, code: result.rawValue)
    }
}
