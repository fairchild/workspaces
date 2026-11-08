// Renders TerminalCanvas offscreen and reads back which grid columns received
// ink (pixels at least half covered, so anti-aliased edges stay in their own
// column), so paint rules the pure tests cannot see, such as whether a decoration
// on a blank cell is drawn at all, are checked against real pixels.
import CoreGraphics
import SwiftUI
import Testing

@testable import TerminalScreen

@MainActor
@Suite("TerminalCanvas rendering")
struct TerminalCanvasRenderingTests {
    @Test("Underline and strikethrough draw over blank cells, as Ghostty draws them")
    func decorationsOnBlanks() throws {
        let terminal = try VirtualTerminal(columns: 6, rows: 1)
        terminal.write("  \u{1B}[4m  \u{1B}[0;9m  \u{1B}[0m\u{1B}[?25l")
        let inked = try inkedColumns(terminal.snapshot())
        #expect(inked == [2, 3, 4, 5])
    }

    private func inkedColumns(_ snapshot: TerminalSnapshot) throws -> Set<Int> {
        let renderer = ImageRenderer(content: TerminalCanvas(snapshot: snapshot, fontSize: 11))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        let columnWidth = Double(width) / Double(snapshot.columns)
        var columns: Set<Int> = []
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 127 {
                columns.insert(min(snapshot.columns - 1, Int((Double(x) + 0.5) / columnWidth)))
            }
        }
        return columns
    }
}
