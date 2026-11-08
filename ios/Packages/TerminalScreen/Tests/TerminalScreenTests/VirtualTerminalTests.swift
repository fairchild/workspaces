// Behavior of the libghostty-vt wrapper as a terminal user would see it:
// what lands on screen after the bytes a program writes, in which style.
import Foundation
import Testing

@testable import TerminalScreen

private let esc = "\u{1B}"

private func screen(
    _ bytes: String,
    columns: Int = 40,
    rows: Int = 6
) throws -> TerminalSnapshot {
    let terminal = try VirtualTerminal(columns: columns, rows: rows)
    terminal.write(bytes)
    return try terminal.snapshot()
}

@Suite("VirtualTerminal")
struct VirtualTerminalTests {
    @Test("Links libghostty-vt 1.x")
    func linksVersionOne() {
        #expect(VirtualTerminal.libraryVersion.hasPrefix("1."))
    }

    @Test("A geometry the library cannot hold is refused, not trapped")
    func invalidGeometry() throws {
        #expect(throws: TerminalError.self) { try VirtualTerminal(columns: 0, rows: 4) }
        #expect(throws: TerminalError.self) { try VirtualTerminal(columns: 80, rows: 70_000) }
        let terminal = try VirtualTerminal(columns: 20, rows: 4)
        #expect(throws: TerminalError.self) { try terminal.resize(columns: -1, rows: 4) }
        #expect(try terminal.snapshot().columns == 20)
    }

    @Test("Plain text lands on screen with trailing blanks trimmed")
    func plainText() throws {
        let snapshot = try screen("hello\r\nworld")
        #expect(snapshot.lines.count == 6)
        #expect(snapshot.lines[0].text == "hello")
        #expect(snapshot.lines[1].text == "world")
        #expect(snapshot.lines[2].runs.isEmpty)
    }

    @Test("A carriage return redraws the line in place, as a progress bar does")
    func carriageReturnOverwrites() throws {
        let snapshot = try screen("[1/42] Compiling\r\(esc)[K[42/42] Done")
        #expect(snapshot.lines[0].text == "[42/42] Done")
    }

    @Test("Cursor-up rewrites an earlier line instead of appending")
    func cursorUpRewrites() throws {
        let snapshot = try screen("spinner\r\nnext\r\n\(esc)[2A\r\(esc)[Kpassed\r\n")
        #expect(snapshot.lines[0].text == "passed")
        #expect(snapshot.lines[1].text == "next")
    }

    @Test("An escape sequence split across writes is completed, not printed")
    func splitSequence() throws {
        let terminal = try VirtualTerminal(columns: 20, rows: 2)
        terminal.write("a\(esc)[3")
        terminal.write("1mred\(esc)[0m")
        let line = try terminal.snapshot().lines[0]
        #expect(line.text == "ared")
        #expect(line.runs.last { !$0.isCursor }?.style.foreground != nil)
        #expect(!line.text.contains(esc))
    }

    @Test("SGR attributes and colors resolve to concrete styles")
    func styles() throws {
        let line = try screen(
            "\(esc)[1;32mok\(esc)[0m \(esc)[38;2;255;128;0morange\(esc)[0m \(esc)[3;4;9mx\(esc)[0m"
        ).lines[0]
        let ok = try #require(line.runs.first { $0.text == "ok" })
        #expect(ok.style.bold)
        #expect(ok.style.foreground != nil)

        let orange = try #require(line.runs.first { $0.text == "orange" })
        #expect(orange.style.foreground == RGB(255, 128, 0))
        #expect(!orange.style.bold)

        let decorated = try #require(line.runs.first { $0.text == "x" })
        #expect(decorated.style.italic && decorated.style.underline && decorated.style.strikethrough)
    }

    @Test("Inverse and background survive as style, so blanks they paint are kept")
    func inverseAndBackground() throws {
        let line = try screen("\(esc)[7m inv \(esc)[0m \(esc)[44m   \(esc)[0m").lines[0]
        #expect(line.runs.contains { $0.style.inverse && $0.text == " inv " })
        let blue = try #require(line.runs.last { !$0.isCursor })
        #expect(blue.style.background != nil)
        #expect(blue.text == "   ")
    }

    @Test("A wide character fills two columns without a doubled spacer")
    func wideCharacters() throws {
        let snapshot = try screen("完成|ok")
        #expect(snapshot.lines[0].text == "完成|ok")
    }

    @Test("The cursor cell is its own run at the exact column, even after wide characters")
    func cursorRun() throws {
        let snapshot = try screen("完成ab\(esc)[2D")
        #expect(snapshot.cursor == TerminalCursor(column: 4, row: 0))
        let runs = snapshot.lines[0].runs
        let cursor = try #require(runs.first { $0.isCursor })
        #expect(cursor.text == "a")
        #expect(runs.filter(\.isCursor).count == 1)
    }

    @Test("A cursor past the written text keeps its blank cell")
    func cursorPastText() throws {
        let line = try screen("$ ").lines[0]
        #expect(line.text == "$")
        #expect(line.runs.last == TextRun(" ", isCursor: true))
        #expect(String(line.runs.map(\.text).joined()) == "$  ")
    }

    @Test("A hidden cursor has no run and no position")
    func hiddenCursor() throws {
        let snapshot = try screen("x\(esc)[?25l")
        #expect(snapshot.cursor == nil)
        #expect(!snapshot.lines.flatMap(\.runs).contains { $0.isCursor })
    }

    @Test("A clean frame returns the same snapshot; a write produces a new one")
    func dirtyTracking() throws {
        let terminal = try VirtualTerminal(columns: 20, rows: 2)
        terminal.write("one")
        let first = try terminal.snapshot()
        #expect(try terminal.snapshot() == first)
        terminal.write(" two")
        #expect(try terminal.snapshot().lines[0].text == "one two")
    }

    @Test("A cursor-only change is not hidden behind the clean-frame cache")
    func cursorOnlyChanges() throws {
        let terminal = try VirtualTerminal(columns: 20, rows: 2)
        terminal.write("abc")
        #expect(try terminal.snapshot().cursor == TerminalCursor(column: 3, row: 0))
        terminal.write("\(esc)[2D")
        let moved = try terminal.snapshot()
        #expect(moved.cursor == TerminalCursor(column: 1, row: 0))
        #expect(moved.lines[0].runs.first { $0.isCursor }?.text == "b")
        terminal.write("\(esc)[?25l")
        #expect(try terminal.snapshot().cursor == nil)
    }

    @Test("A cursor on the right half of a wide character marks the whole character")
    func cursorOnSpacerTail() throws {
        let snapshot = try screen("完\(esc)[1D", columns: 4, rows: 1)
        #expect(snapshot.cursor == TerminalCursor(column: 1, row: 0))
        let cursor = try #require(snapshot.paintedCells().first { $0.text == "完" })
        #expect(cursor.column == 0 && cursor.width == 2)
        #expect(cursor.background == snapshot.foreground)
    }

    @Test("A cursor on the cell a wrapped wide character left behind still shows")
    func cursorOnSpacerHead() throws {
        let snapshot = try screen("abc完\(esc)[1;4H", columns: 4, rows: 2)
        #expect(snapshot.cursor == TerminalCursor(column: 3, row: 0))
        let runs = snapshot.lines[0].runs
        #expect(runs.filter(\.isCursor).count == 1)
        #expect(runs.last == TextRun(" ", isCursor: true))
    }

    @Test("Resize reflows the viewport to the new geometry")
    func resize() throws {
        let terminal = try VirtualTerminal(columns: 20, rows: 4)
        terminal.write("abc")
        try terminal.resize(columns: 10, rows: 2)
        let snapshot = try terminal.snapshot()
        #expect(snapshot.columns == 10)
        #expect(snapshot.lines.count == 2)
        #expect(snapshot.lines[0].text.hasPrefix("abc"))
    }

    @Test("A recorded agent turn renders as the final screen, with no escape bytes left")
    func recordedTurn() throws {
        let terminal = try VirtualTerminal(columns: 60, rows: 14)
        terminal.write(try FixtureCorpus.stream("agent-turn"))
        let snapshot = try terminal.snapshot()
        let text = snapshot.text

        #expect(!text.contains(esc))
        #expect(text.contains("Build complete! (3.21s)"))
        #expect(!text.contains("Compiling"))
        #expect(text.contains("✔ 6 tests passed"))
        #expect(!text.contains("running 6 tests"))
        #expect(text.contains("wide: 完成 ✅"))
        #expect(snapshot.lines.first?.text.hasPrefix("~/project ❯ swift test") == true)
    }
}

@Suite("TerminalSnapshot painting")
struct TerminalSnapshotPaintingTests {
    @Test("Glyphs sit on the cell grid: a wide character advances two columns")
    func wideCharactersAdvanceTwoColumns() throws {
        let cells = try screen("完成|ok\(esc)[?25l").paintedCells()
        #expect(cells.map(\.text) == ["完", "成", "|", "o", "k"])
        #expect(cells.map(\.column) == [0, 2, 4, 5, 6])
        #expect(cells.map(\.width) == [2, 2, 1, 1, 1])
    }

    @Test("Cells Swift would fuse into one grapheme stay in their own columns")
    func adjacentCellsDoNotFuse() throws {
        let cells = try screen("©\u{200D}®X\(esc)[?25l").paintedCells()
        #expect(cells.map(\.column) == [0, 1, 2])
        #expect(cells.map(\.width) == [1, 1, 1])
        #expect(cells.last?.text == "X")
    }

    @Test("A cell the terminal clusters into several Swift Characters paints as one cell")
    func clusteredCellStaysOneCell() throws {
        let cells = try screen("\(esc)[?2027hA\u{05C8}X\(esc)[?25l").paintedCells()
        #expect(cells.map(\.text) == ["A\u{05C8}", "X"])
        #expect(cells.map(\.column) == [0, 1])
        #expect(cells.map(\.width) == [1, 1])

        let boxed = try screen("\(esc)[?2027h─\u{05C8}X\(esc)[?25l").paintedCells()
        #expect(boxed.first?.text == "─\u{05C8}")
        #expect(boxed.first?.boxDrawing == nil)
        #expect(try screen("─\(esc)[?25l").paintedCells().first?.boxDrawing == BoxDrawing("─"))

        let wide = try screen("\(esc)[?2027h完\u{05C8}\(esc)[1D", columns: 4, rows: 1)
        #expect(wide.cursor == TerminalCursor(column: 1, row: 0))
        #expect(wide.lines[0].runs.filter(\.isCursor).map(\.columns) == [2])
    }

    @Test("The cursor cell paints inverted in the default colors; hiding it restores them")
    func cursorPaintsInverted() throws {
        let snapshot = try screen("$ ")
        let cursor = try #require(snapshot.paintedCells().last)
        #expect(cursor.column == 2)
        #expect(cursor.foreground == snapshot.background)
        #expect(cursor.background == snapshot.foreground)

        let hidden = try #require(snapshot.paintedCells(showCursor: false).last)
        #expect(hidden.foreground == snapshot.foreground)
        #expect(hidden.background == nil)
    }

    @Test("A cursor over an inverse cell paints in the cursor's colors, as Ghostty's block overlay does")
    func cursorOverInverse() throws {
        let snapshot = try screen("\(esc)[2;7;44mabcdefg完\(esc)[1;8H", columns: 8, rows: 3)
        #expect(snapshot.cursor == TerminalCursor(column: 7, row: 0))
        let cells = snapshot.paintedCells()
        let cursor = try #require(cells.first { $0.row == 0 && $0.column == 7 })
        #expect(cursor.text == " ")
        #expect(cursor.foreground == snapshot.background)
        #expect(cursor.background == snapshot.foreground)
        #expect(cursor.foregroundOpacity == 1)
        let beside = try #require(cells.first { $0.row == 0 && $0.column == 6 })
        #expect(beside.foreground != snapshot.background && beside.foregroundOpacity < 1)
    }

    @Test("Underline and strikethrough lines cover blank cells too, merged per run")
    func decorationLinesCoverBlanks() throws {
        let cells = try screen("  \(esc)[4m  \(esc)[0;9m ok\(esc)[0m\(esc)[?25l").paintedCells()
        let lines = cells.decorationLines()
        #expect(lines.map(\.kind) == [.underline, .strikethrough])
        #expect(lines.map(\.column) == [2, 4])
        #expect(lines.map(\.width) == [2, 3])
    }

    @Test("Inverse swaps resolved colors; faint dims; invisible matches its background")
    func paintTimeAttributes() throws {
        let snapshot = try screen("\(esc)[7;31mI\(esc)[0m\(esc)[2mF\(esc)[0m\(esc)[8;44mH\(esc)[0m\(esc)[?25l")
        let cells = snapshot.paintedCells()
        let inverse = cells[0], faint = cells[1], invisible = cells[2]
        #expect(inverse.foreground == snapshot.background)
        #expect(inverse.background != nil && inverse.background != snapshot.foreground)
        #expect(faint.foregroundOpacity < 1)
        #expect(invisible.foreground == invisible.background)
    }

    @Test("Adjacent same-colored backgrounds paint as one span")
    func backgroundSpansMerge() throws {
        let cells = try screen("\(esc)[44mab完\(esc)[41mc\(esc)[0m d\(esc)[?25l").paintedCells()
        let spans = cells.backgroundSpans()
        #expect(spans.map(\.column) == [0, 4])
        #expect(spans.map(\.width) == [4, 1])
        #expect(spans[0].color != spans[1].color)
    }
}

@Suite("BoxDrawing")
struct BoxDrawingTests {
    @Test("Light lines and corners map to the edges they join")
    func edges() {
        #expect(BoxDrawing("─")?.edges == [.left, .right])
        #expect(BoxDrawing("┼")?.edges == [.left, .right, .up, .down])
        #expect(BoxDrawing("╭") == BoxDrawing(edges: [.right, .down], rounded: true))
        #expect(BoxDrawing("┌")?.rounded == false)
    }

    @Test("Segments reach exactly the edges they join and never overlap")
    func segmentGeometry() throws {
        let cell = CGRect(x: 10, y: 20, width: 7.4, height: 15)
        for character: Character in ["─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼"] {
            let box = try #require(BoxDrawing(character))
            let rects = box.segmentRects(in: cell, thickness: 2)
            for (i, a) in rects.enumerated() {
                for b in rects[(i + 1)...] {
                    let shared = a.intersection(b)
                    #expect(shared.isNull || shared.width * shared.height == 0, "\(character) overlaps")
                }
            }
            #expect(rects.contains { $0.minX == cell.minX } == box.edges.contains(.left), "\(character) left")
            #expect(rects.contains { $0.maxX == cell.maxX } == box.edges.contains(.right), "\(character) right")
            #expect(rects.contains { $0.minY == cell.minY } == box.edges.contains(.up), "\(character) up")
            #expect(rects.contains { $0.maxY == cell.maxY } == box.edges.contains(.down), "\(character) down")
        }
        #expect(BoxDrawing("╭")?.segmentRects(in: cell, thickness: 2).isEmpty == true)
    }

    @Test("Heavy, double, and ordinary characters keep their glyphs")
    func passThrough() {
        for character: Character in ["━", "═", "┄", "a", "|", "-"] {
            #expect(BoxDrawing(character) == nil)
        }
    }
}
