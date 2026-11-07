// Draws a TerminalSnapshot on a fixed cell grid. Every glyph is placed at
// column × cell width, so fallback-font glyphs (CJK, emoji) cannot push the
// rest of a line out of alignment the way flowing text does. Paint-time
// decisions — inverse, invisible, faint, the cursor block, background spans —
// are pure and tested; the view only draws their output, with light box
// drawing stroked as geometry (BoxDrawing.swift).
import SwiftUI

/// One glyph at its grid position with its colors resolved for painting.
public struct PaintedCell: Hashable, Sendable {
    public var row: Int
    public var column: Int
    public var width: Int
    public var text: String
    public var foreground: RGB
    public var foregroundOpacity: Double
    /// nil leaves the screen background showing.
    public var background: RGB?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
}

extension TerminalSnapshot {
    public func paintedCells(showCursor: Bool = true) -> [PaintedCell] {
        var cells: [PaintedCell] = []
        for (row, line) in lines.enumerated() {
            var column = 0
            for run in line.runs {
                var style = run.style
                if showCursor && run.isCursor { style.inverse.toggle() }
                if run.cells == 1 {
                    cells.append(paint(run.text, row: row, column: column, width: run.columns, style: style))
                    column += run.columns
                    continue
                }
                for character in run.text {
                    cells.append(paint(String(character), row: row, column: column, width: 1, style: style))
                    column += 1
                }
            }
        }
        return cells
    }

    private func paint(_ text: String, row: Int, column: Int, width: Int, style: CellStyle) -> PaintedCell {
        var foreground = style.foreground ?? self.foreground
        var background = style.background
        if style.inverse { (foreground, background) = (background ?? self.background, foreground) }
        if style.invisible { foreground = background ?? self.background }
        return PaintedCell(
            row: row,
            column: column,
            width: width,
            text: text,
            foreground: foreground,
            foregroundOpacity: style.faint ? 0.6 : 1,
            background: background,
            bold: style.bold,
            italic: style.italic,
            underline: style.underline,
            strikethrough: style.strikethrough
        )
    }
}

extension PaintedCell {
    /// Drawn as geometry only when the cell is the line character alone; a
    /// cell that also carries a combining mark keeps its font glyph.
    var boxDrawing: BoxDrawing? {
        guard text.count == 1, let character = text.first else { return nil }
        return BoxDrawing(character)
    }
}

/// A horizontal stretch of one background color.
public struct BackgroundSpan: Hashable, Sendable {
    public var row: Int
    public var column: Int
    public var width: Int
    public var color: RGB
}

extension [PaintedCell] {
    /// Adjacent same-colored backgrounds merged into one span, so a filled
    /// region paints as a single rect instead of per-cell rects whose
    /// anti-aliased edges leave hairline seams between cells.
    public func backgroundSpans() -> [BackgroundSpan] {
        var spans: [BackgroundSpan] = []
        for cell in self {
            guard let color = cell.background else { continue }
            if let last = spans.indices.last, spans[last].row == cell.row, spans[last].color == color,
                spans[last].column + spans[last].width == cell.column
            {
                spans[last].width += cell.width
            } else {
                spans.append(BackgroundSpan(row: cell.row, column: cell.column, width: cell.width, color: color))
            }
        }
        return spans
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

/// A read-only terminal screen. Scrolls rather than reflowing, because a
/// program laid its output out for exactly these columns.
public struct TerminalScreenView: View {
    public var snapshot: TerminalSnapshot
    public var fontSize: CGFloat

    public init(snapshot: TerminalSnapshot, fontSize: CGFloat = 11) {
        self.snapshot = snapshot
        self.fontSize = fontSize
    }

    public var body: some View {
        ScrollView([.horizontal, .vertical]) {
            TerminalCanvas(snapshot: snapshot, fontSize: fontSize)
                .padding(8)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(snapshot.background))
        .accessibilityElement()
        .accessibilityLabel(Text(snapshot.text))
    }
}

/// The grid itself, sized to exactly columns × rows cells.
struct TerminalCanvas: View {
    var snapshot: TerminalSnapshot
    var fontSize: CGFloat

    var body: some View {
        let cell = CellMetrics(fontSize: fontSize)
        let cells = snapshot.paintedCells()
        Canvas { context, _ in
            for span in cells.backgroundSpans() {
                let rect = cell.rect(row: span.row, column: span.column, width: span.width)
                context.fill(Path(rect), with: .color(Color(span.color)))
            }
            var boxes: [BoxStroke: (segments: Path, arcs: Path)] = [:]
            for painted in cells where painted.text != " " {
                let rect = cell.rect(row: painted.row, column: painted.column, width: painted.width)
                if let box = painted.boxDrawing {
                    let stroke = BoxStroke(painted)
                    boxes[stroke, default: (Path(), Path())].segments
                        .addPath(box.segments(in: rect, thickness: stroke.lineWidth))
                    boxes[stroke, default: (Path(), Path())].arcs.addPath(box.arc(in: rect))
                } else {
                    context.draw(glyph(painted), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                }
            }
            for (stroke, paths) in boxes {
                let shading = GraphicsContext.Shading.color(Color(stroke.color).opacity(stroke.opacity))
                context.fill(paths.segments, with: shading)
                context.stroke(paths.arcs, with: shading, lineWidth: stroke.lineWidth)
            }
        }
        .frame(
            width: CGFloat(snapshot.columns) * cell.width,
            height: CGFloat(snapshot.rows) * cell.height
        )
    }

    private func glyph(_ cell: PaintedCell) -> Text {
        Text(cell.text)
            .font(.system(size: fontSize, design: .monospaced))
            .bold(cell.bold)
            .italic(cell.italic)
            .underline(cell.underline)
            .strikethrough(cell.strikethrough)
            .foregroundColor(Color(cell.foreground).opacity(cell.foregroundOpacity))
    }
}

private struct BoxStroke: Hashable {
    let color: RGB
    let opacity: Double
    let lineWidth: CGFloat

    init(_ cell: PaintedCell) {
        color = cell.foreground
        opacity = cell.foregroundOpacity
        lineWidth = cell.bold ? 2 : 1
    }
}

/// The grid cell for the system monospaced font at a size: one advance wide,
/// one line tall.
struct CellMetrics {
    let width: CGFloat
    let height: CGFloat

    init(fontSize: CGFloat) {
        #if canImport(UIKit)
            let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            width = ("M" as NSString).size(withAttributes: [.font: font]).width
            height = font.lineHeight.rounded(.up)
        #else
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            width = ("M" as NSString).size(withAttributes: [.font: font]).width
            height = (font.ascender - font.descender + font.leading).rounded(.up)
        #endif
    }

    func rect(row: Int, column: Int, width: Int) -> CGRect {
        CGRect(
            x: CGFloat(column) * self.width,
            y: CGFloat(row) * height,
            width: CGFloat(width) * self.width,
            height: height
        )
    }
}
