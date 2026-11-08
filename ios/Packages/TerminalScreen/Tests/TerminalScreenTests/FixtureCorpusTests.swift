// Replays the shared libghostty-vt fixture corpus (`fixtures/terminal-vt/` at
// the repo root) and compares each final screen with its golden. web-next's
// fixture-corpus.test.ts replays the same files against the same goldens, so
// the two bindings answer to one contract. Goldens hold only the fields both
// snapshots expose, in a canonical run shape both tests derive.
import Foundation
import Testing

@testable import TerminalScreen

enum FixtureCorpus {
    struct Fixture: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let columns: Int
        let rows: Int
        /// Bytes per write; the whole stream in one write when absent.
        let chunk: Int?

        var testDescription: String { name }
    }

    /// Found from this file's path: SwiftPM copies resources only from inside
    /// the target, and the corpus is shared with web-next.
    static let directory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            let candidate = url.appending(path: "fixtures/terminal-vt")
            if FileManager.default.fileExists(atPath: candidate.appending(path: "corpus.json").path) {
                return candidate
            }
        }
        return url
    }()

    static func manifest() throws -> [Fixture] {
        struct Manifest: Decodable { let fixtures: [Fixture] }
        let data = try Data(contentsOf: directory.appending(path: "corpus.json"))
        return try JSONDecoder().decode(Manifest.self, from: data).fixtures
    }

    /// Empty when the manifest is missing or malformed; the manifest test
    /// reports why, so the replay cannot pass by replaying nothing.
    static let fixtures: [Fixture] = (try? manifest()) ?? []

    static func stream(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).vt"))
    }
}

/// Only set fields appear: nil means the default color, or the attribute off.
struct GoldenStyle: Codable, Equatable, CustomStringConvertible {
    var fg: String?
    var bg: String?
    var bold: Bool?
    var italic: Bool?
    var faint: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var inverse: Bool?
    var invisible: Bool?

    var description: String {
        let flags: [(String, Bool?)] = [
            ("bold", bold), ("italic", italic), ("faint", faint), ("underline", underline),
            ("strikethrough", strikethrough), ("inverse", inverse), ("invisible", invisible),
        ]
        let colors = [fg.map { "fg \($0)" }, bg.map { "bg \($0)" }].compactMap { $0 }
        return (colors + flags.filter { $0.1 == true }.map(\.0)).joined(separator: " ")
    }
}

struct GoldenRun: Codable, Equatable, CustomStringConvertible {
    var column: Int
    var text: String
    var columns: Int
    var style: GoldenStyle?

    /// By code point: Swift's String equality is canonical, so "e\u{301}"
    /// would otherwise pass for "é".
    static func == (a: GoldenRun, b: GoldenRun) -> Bool {
        a.column == b.column && a.columns == b.columns && a.style == b.style
            && a.text.unicodeScalars.elementsEqual(b.text.unicodeScalars)
    }

    var description: String {
        let scalars = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
        return "column \(column) [\(scalars)] \"\(text)\" ×\(columns) \(style?.description ?? "plain")"
    }
}

struct GoldenCursor: Codable, Equatable {
    var column: Int
    var row: Int
    var wide: Bool
}

struct Golden: Codable, Equatable {
    var columns: Int
    var rows: Int
    var fg: String
    var bg: String
    var cursor: GoldenCursor?
    var lines: [[GoldenRun]]
}

extension Golden {
    /// The canonical shape: each run split back into cells, trailing blanks
    /// that paint nothing dropped, then narrow single-code-point cells of one
    /// style merged. A wide cell, or a cell holding several code points, is a
    /// run of its own, so `text` splits back into cells without either
    /// language's grapheme rules. The cursor is position only, plus whether it
    /// sits on the right half of a wide character.
    init(_ snapshot: TerminalSnapshot) {
        let lines = snapshot.lines.map { Self.canonicalRuns(Self.cells(of: $0)) }
        var cursor: GoldenCursor?
        if let at = snapshot.cursor {
            let rightHalf = lines[at.row].contains { $0.columns == 2 && $0.column + 1 == at.column }
            cursor = GoldenCursor(column: at.column, row: at.row, wide: rightHalf)
        }
        self.init(
            columns: snapshot.columns,
            rows: snapshot.rows,
            fg: hex(snapshot.foreground),
            bg: hex(snapshot.background),
            cursor: cursor,
            lines: lines
        )
    }

    private struct Cell {
        var column: Int
        var text: String
        var width: Int
        var style: CellStyle
    }

    /// A run of several cells holds exactly one Character per cell, so its
    /// Characters are its cells.
    private static func cells(of line: TerminalLine) -> [Cell] {
        var column = 0
        var cells: [Cell] = []
        for run in line.runs {
            if run.cells == 1 {
                cells.append(Cell(column: column, text: run.text, width: run.columns, style: run.style))
            } else {
                for (offset, character) in run.text.enumerated() {
                    cells.append(Cell(column: column + offset, text: String(character), width: 1, style: run.style))
                }
            }
            column += run.columns
        }
        return cells
    }

    private static func canonicalRuns(_ cells: [Cell]) -> [GoldenRun] {
        var kept = cells[...]
        while let last = kept.last, last.text == " ", !last.style.paintsBlank { kept.removeLast() }
        var runs: [GoldenRun] = []
        var mergeable = false
        for cell in kept {
            let narrow = cell.width == 1 && cell.text.unicodeScalars.count == 1
            let style = goldenStyle(cell.style)
            if narrow, mergeable, let last = runs.last, last.column + last.columns == cell.column, last.style == style {
                runs[runs.count - 1].text.unicodeScalars.append(contentsOf: cell.text.unicodeScalars)
                runs[runs.count - 1].columns += 1
                continue
            }
            runs.append(GoldenRun(column: cell.column, text: cell.text, columns: cell.width, style: style))
            mergeable = narrow
        }
        return runs
    }

    private static func goldenStyle(_ style: CellStyle) -> GoldenStyle? {
        let flag = { (on: Bool) in on ? true : nil }
        let golden = GoldenStyle(
            fg: style.foreground.map(hex),
            bg: style.background.map(hex),
            bold: flag(style.bold),
            italic: flag(style.italic),
            faint: flag(style.faint),
            underline: flag(style.underline),
            strikethrough: flag(style.strikethrough),
            inverse: flag(style.inverse),
            invisible: flag(style.invisible)
        )
        return golden == GoldenStyle() ? nil : golden
    }
}

private func hex(_ rgb: RGB) -> String {
    String(format: "#%02x%02x%02x", rgb.red, rgb.green, rgb.blue)
}

@Suite("libghostty-vt fixture corpus")
struct FixtureCorpusTests {
    @Test("The manifest lists every stream in the corpus directory")
    func manifestCoversCorpus() throws {
        let streams = try FileManager.default.contentsOfDirectory(atPath: FixtureCorpus.directory.path)
            .filter { $0.hasSuffix(".vt") }
            .map { String($0.dropLast(3)) }
            .sorted()
        #expect(!streams.isEmpty, "no corpus at \(FixtureCorpus.directory.path)")
        #expect(try FixtureCorpus.manifest().map(\.name).sorted() == streams)
    }

    @Test("Replays to its golden", arguments: FixtureCorpus.fixtures)
    func replay(_ fixture: FixtureCorpus.Fixture) throws {
        let terminal = try VirtualTerminal(columns: fixture.columns, rows: fixture.rows)
        let stream = try FixtureCorpus.stream(fixture.name)
        let chunk = fixture.chunk ?? stream.count
        for start in stride(from: 0, to: stream.count, by: chunk) {
            terminal.write(stream[start..<min(start + chunk, stream.count)])
        }
        let actual = Golden(try terminal.snapshot())
        let path = FixtureCorpus.directory.appending(path: "\(fixture.name).golden.json")
        let expected = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: path))

        #expect(actual.columns == expected.columns && actual.rows == expected.rows, "\(fixture.name) grid")
        #expect(actual.fg == expected.fg && actual.bg == expected.bg, "\(fixture.name) default colors")
        #expect(actual.cursor == expected.cursor, "\(fixture.name) cursor")
        try #require(actual.lines.count == expected.lines.count, "\(fixture.name) line count")
        for (row, line) in actual.lines.enumerated() {
            #expect(line == expected.lines[row], "\(fixture.name) row \(row)")
        }
    }
}
