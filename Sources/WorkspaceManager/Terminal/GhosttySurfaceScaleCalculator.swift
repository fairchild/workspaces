//
//  GhosttySurfaceScaleCalculator.swift
//  WorkspaceManager
//

import CoreGraphics
import Foundation

enum GhosttySurfaceScaleCalculator {
    struct ScaleAndSize: Equatable {
        let xScale: CGFloat
        let yScale: CGFloat
        let width: UInt32
        let height: UInt32
    }

    enum Decision: Equatable {
        case skip
        case unchanged
        case update(ScaleAndSize)
    }

    static func decide(
        bounds: CGRect,
        backingBounds: CGRect,
        last: ScaleAndSize?
    ) -> Decision {
        guard bounds.width > 0, bounds.height > 0 else { return .skip }

        let xScale = backingBounds.width / bounds.width
        let yScale = backingBounds.height / bounds.height
        let width = UInt32(max(1, Int(backingBounds.width)))
        let height = UInt32(max(1, Int(backingBounds.height)))

        let next = ScaleAndSize(xScale: xScale, yScale: yScale, width: width, height: height)

        if let last, last == next {
            return .unchanged
        }

        return .update(next)
    }
}
