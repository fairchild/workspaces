// Light box-drawing characters as cell geometry. Font glyphs for these rarely
// span the full cell, so a border drawn from them breaks into dashes; drawing
// each as strokes from the cell's center to its edges joins neighbors into
// continuous lines, the way terminals render them. Heavy, double, and dashed
// variants keep their font glyphs.

struct BoxDrawing: Equatable {
    struct Edges: OptionSet, Hashable {
        let rawValue: UInt8
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let up = Edges(rawValue: 1 << 2)
        static let down = Edges(rawValue: 1 << 3)
    }

    let edges: Edges
    /// Corners drawn as a quarter arc (╭╮╰╯) rather than a right angle.
    let rounded: Bool

    init(edges: Edges, rounded: Bool) {
        self.edges = edges
        self.rounded = rounded
    }

    init?(_ character: Character) {
        switch character {
        case "─": (edges, rounded) = ([.left, .right], false)
        case "│": (edges, rounded) = ([.up, .down], false)
        case "┌": (edges, rounded) = ([.right, .down], false)
        case "┐": (edges, rounded) = ([.left, .down], false)
        case "└": (edges, rounded) = ([.right, .up], false)
        case "┘": (edges, rounded) = ([.left, .up], false)
        case "├": (edges, rounded) = ([.up, .down, .right], false)
        case "┤": (edges, rounded) = ([.up, .down, .left], false)
        case "┬": (edges, rounded) = ([.left, .right, .down], false)
        case "┴": (edges, rounded) = ([.left, .right, .up], false)
        case "┼": (edges, rounded) = ([.left, .right, .up, .down], false)
        case "╭": (edges, rounded) = ([.right, .down], true)
        case "╮": (edges, rounded) = ([.left, .down], true)
        case "╰": (edges, rounded) = ([.right, .up], true)
        case "╯": (edges, rounded) = ([.left, .up], true)
        default: return nil
        }
    }
}

#if canImport(SwiftUI)
    import SwiftUI

    extension BoxDrawing {
        /// Straight segments as rectangles reaching the cell edges they join,
        /// so neighbors abut into one continuous line. The rectangles never
        /// overlap: one horizontal bar, and vertical pieces that stop at it.
        /// Overlapping coverage would blend twice in anti-aliased rows and
        /// show as a dark notch at every cell center. Rounded corners are
        /// empty here and drawn by `arc(in:)`.
        func segments(in rect: CGRect, thickness: CGFloat) -> Path {
            var path = Path()
            path.addRects(segmentRects(in: rect, thickness: thickness))
            return path
        }

        func segmentRects(in rect: CGRect, thickness: CGFloat) -> [CGRect] {
            guard !rounded else { return [] }
            let half = thickness / 2
            let bar = CGRect(x: rect.midX - half, y: rect.midY - half, width: thickness, height: thickness)
            let horizontal = !edges.isDisjoint(with: [.left, .right])
            var rects: [CGRect] = []
            if horizontal {
                let minX = edges.contains(.left) ? rect.minX : bar.minX
                let maxX = edges.contains(.right) ? rect.maxX : bar.maxX
                rects.append(CGRect(x: minX, y: bar.minY, width: maxX - minX, height: thickness))
            }
            let up = edges.contains(.up), down = edges.contains(.down)
            func vertical(_ minY: CGFloat, _ maxY: CGFloat) {
                rects.append(CGRect(x: bar.minX, y: minY, width: thickness, height: maxY - minY))
            }
            if horizontal {
                if up { vertical(rect.minY, bar.minY) }
                if down { vertical(bar.maxY, rect.maxY) }
            } else if up || down {
                vertical(up ? rect.minY : bar.minY, down ? rect.maxY : bar.maxY)
            }
            return rects
        }

        /// A rounded corner as a quarter curve between its two edge midpoints,
        /// for stroking at the segment thickness.
        func arc(in rect: CGRect) -> Path {
            var path = Path()
            guard rounded else { return path }
            let ends: [(Edges, CGPoint)] = [
                (.left, CGPoint(x: rect.minX, y: rect.midY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY)),
                (.up, CGPoint(x: rect.midX, y: rect.minY)),
                (.down, CGPoint(x: rect.midX, y: rect.maxY)),
            ]
            let points = ends.filter { edges.contains($0.0) }.map(\.1)
            path.move(to: points[0])
            path.addQuadCurve(to: points[1], control: CGPoint(x: rect.midX, y: rect.midY))
            return path
        }
    }
#endif
