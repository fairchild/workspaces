//
//  GhosttySurfaceScaleCalculatorTests.swift
//  WorkspaceManagerAppTests
//

import CoreGraphics
import Testing

@testable import WorkspaceManager

@Suite("GhosttySurfaceScaleCalculator")
struct GhosttySurfaceScaleCalculatorTests {
    @Test("Zero-width bounds skip the update")
    func zeroWidthBoundsSkip() {
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: CGRect(x: 0, y: 0, width: 0, height: 100),
            backingBounds: CGRect(x: 0, y: 0, width: 0, height: 200),
            last: nil
        )
        #expect(decision == .skip)
    }

    @Test("Zero-height bounds skip the update")
    func zeroHeightBoundsSkip() {
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 0),
            backingBounds: CGRect(x: 0, y: 0, width: 200, height: 0),
            last: nil
        )
        #expect(decision == .skip)
    }

    @Test("First computation with no prior value produces an update")
    func firstComputationProducesUpdate() {
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            backingBounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            last: nil
        )

        let expected = GhosttySurfaceScaleCalculator.ScaleAndSize(
            xScale: 2,
            yScale: 2,
            width: 200,
            height: 100
        )
        #expect(decision == .update(expected))
    }

    @Test("Matching prior value returns unchanged")
    func matchingPriorReturnsUnchanged() {
        let last = GhosttySurfaceScaleCalculator.ScaleAndSize(
            xScale: 2,
            yScale: 2,
            width: 200,
            height: 100
        )
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            backingBounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            last: last
        )
        #expect(decision == .unchanged)
    }

    @Test("Changed scale produces an update even when size is unchanged")
    func changedScaleProducesUpdate() {
        let last = GhosttySurfaceScaleCalculator.ScaleAndSize(
            xScale: 1,
            yScale: 1,
            width: 200,
            height: 100
        )
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            backingBounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            last: last
        )

        let expected = GhosttySurfaceScaleCalculator.ScaleAndSize(
            xScale: 2,
            yScale: 2,
            width: 200,
            height: 100
        )
        #expect(decision == .update(expected))
    }

    @Test("Sub-pixel backing dimensions clamp to at least one pixel")
    func subPixelBackingClampsToOne() {
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            backingBounds: CGRect(x: 0, y: 0, width: 0.4, height: 0.4),
            last: nil
        )

        guard case .update(let next) = decision else {
            Issue.record("expected .update decision, got \(decision)")
            return
        }
        #expect(next.width == 1)
        #expect(next.height == 1)
    }
}
