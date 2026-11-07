// The value a renderer draws: one viewport of terminal state, already
// resolved to text runs and concrete colors. Snapshots are plain Sendable
// values, so they cross actors freely while the emulator that produced them
// stays put.

public struct RGB: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct CellStyle: Hashable, Sendable {
    /// nil draws with the snapshot's default foreground.
    public var foreground: RGB?
    /// nil draws with the snapshot's default background.
    public var background: RGB?
    public var bold = false
    public var italic = false
    public var faint = false
    public var underline = false
    public var strikethrough = false
    public var inverse = false
    public var invisible = false

    public init(foreground: RGB? = nil, background: RGB? = nil) {
        self.foreground = foreground
        self.background = background
    }

    public static let plain = CellStyle()

    /// Whether a blank cell in this style looks different from an unwritten
    /// one — the test for keeping trailing spaces.
    var paintsBlank: Bool { background != nil || inverse || underline || strikethrough }
}

/// Consecutive cells of one row sharing a style, shaped so a renderer can
/// place every glyph on the grid without measuring it. A run of several
/// cells holds narrow cells of exactly one Character each. A run of one cell
/// holds that cell's whole grapheme, which may be several Swift Characters
/// when the terminal clusters differently, across `columns` columns (2 for a
/// wide character). The cursor's cell is always a run of its own.
public struct TextRun: Hashable, Sendable {
    public internal(set) var text: String
    public internal(set) var style: CellStyle
    public internal(set) var isCursor: Bool
    /// Grid columns the run covers.
    public internal(set) var columns: Int
    /// Grid cells the run holds; a wide cell is one cell over two columns.
    public internal(set) var cells: Int

    /// Narrow cells of one Character each.
    public init(_ text: String, style: CellStyle = .plain, isCursor: Bool = false) {
        self.init(text, style: style, isCursor: isCursor, columns: text.count, cells: text.count)
    }

    /// One terminal cell holding `text` whole across `columns` columns.
    init(cell text: String, columns: Int, style: CellStyle, isCursor: Bool) {
        self.init(text, style: style, isCursor: isCursor, columns: columns, cells: 1)
    }

    private init(_ text: String, style: CellStyle, isCursor: Bool, columns: Int, cells: Int) {
        self.text = text
        self.style = style
        self.isCursor = isCursor
        self.columns = columns
        self.cells = cells
    }
}

public struct TerminalLine: Hashable, Sendable {
    public var runs: [TextRun]

    public init(runs: [TextRun]) {
        self.runs = runs
    }

    /// What copying the line would give: its characters with trailing
    /// blanks dropped, including the blank a cursor past the text occupies.
    public var text: String {
        String(runs.map(\.text).joined().reversed().drop(while: { $0 == " " }).reversed())
    }
}

public struct TerminalCursor: Hashable, Sendable {
    public var column: Int
    public var row: Int
}

public struct TerminalSnapshot: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    public var foreground: RGB
    public var background: RGB
    /// nil when the cursor is hidden or outside the viewport.
    public var cursor: TerminalCursor?
    public var lines: [TerminalLine]

    public init(
        columns: Int,
        rows: Int,
        foreground: RGB,
        background: RGB,
        cursor: TerminalCursor?,
        lines: [TerminalLine]
    ) {
        self.columns = columns
        self.rows = rows
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.lines = lines
    }

    /// The viewport as plain text, one line per row.
    public var text: String { lines.map(\.text).joined(separator: "\n") }
}
