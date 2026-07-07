import Foundation
import Testing

@testable import WorkspaceManager

@Suite("WorkspaceStatusAggregationCoalescer")
struct WorkspaceStatusAggregationCoalescerTests {
    /// Deterministic stand-in for the coalescer's window timer. The injected sleep
    /// announces on `parked` when a flush task has reached the window, then suspends
    /// until the test calls `release()`. Driving both sides through explicit signals
    /// keeps the tests free of wall-clock or yield-budget timing assumptions, which
    /// otherwise flake under the parallel `@MainActor` suite.
    private final class WindowClock: @unchecked Sendable {
        let parked: AsyncStream<Void>
        private let parkedContinuation: AsyncStream<Void>.Continuation
        private let gate = Gate()

        init() {
            (parked, parkedContinuation) = AsyncStream<Void>.makeStream()
        }

        func sleep() async {
            parkedContinuation.yield(())
            await gate.wait()
        }

        func release() async {
            await gate.release()
        }

        /// Async counting semaphore starting at zero. `release()` before a matching
        /// `wait()` is banked rather than lost, so the test never hangs on the order
        /// in which the flush task registers versus when the test releases.
        private actor Gate {
            private var pendingReleases = 0
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func wait() async {
                if pendingReleases > 0 {
                    pendingReleases -= 1
                    return
                }
                await withCheckedContinuation { waiters.append($0) }
            }

            func release() {
                if waiters.isEmpty {
                    pendingReleases += 1
                } else {
                    waiters.removeFirst().resume()
                }
            }
        }
    }

    @Test("Rapid schedules collapse to a single trailing-edge pass on the final state")
    @MainActor
    func rapidSchedulesCollapseToSingleTrailingPass() async {
        let clock = WindowClock()
        let coalescer = WorkspaceStatusAggregationCoalescer(sleep: { _ in await clock.sleep() })
        var parkedIterator = clock.parked.makeAsyncIterator()
        let (ran, ranContinuation) = AsyncStream<Int>.makeStream()
        var ranIterator = ran.makeAsyncIterator()

        var runCount = 0

        // Each closure carries its own value (captured at schedule time), so the
        // recorded value proves *which* request ran, not merely how many.
        for value in 1...5 {
            coalescer.schedule {
                runCount += 1
                ranContinuation.yield(value)
            }
        }

        // Nothing runs while the window is still open.
        #expect(runCount == 0)

        await parkedIterator.next()
        await clock.release()

        // Five rapid requests produce exactly one aggregation, and it observes the
        // final state (trailing edge) — the sidebar cannot settle on stale status.
        let observed = await ranIterator.next()
        #expect(observed == 5)
        #expect(runCount == 1)
    }

    @Test("A request after a completed window runs its own trailing-edge pass")
    @MainActor
    func requestAfterWindowRunsAgain() async {
        let clock = WindowClock()
        let coalescer = WorkspaceStatusAggregationCoalescer(sleep: { _ in await clock.sleep() })
        var parkedIterator = clock.parked.makeAsyncIterator()
        let (ran, ranContinuation) = AsyncStream<Int>.makeStream()
        var ranIterator = ran.makeAsyncIterator()

        var runCount = 0

        for value in 1...3 {
            coalescer.schedule {
                runCount += 1
                ranContinuation.yield(value)
            }
        }
        await parkedIterator.next()
        await clock.release()
        let firstObserved = await ranIterator.next()

        // A later burst is not swallowed by the first window: the final update always runs.
        coalescer.schedule {
            runCount += 1
            ranContinuation.yield(9)
        }
        await parkedIterator.next()
        await clock.release()
        let secondObserved = await ranIterator.next()

        #expect(firstObserved == 3)
        #expect(secondObserved == 9)
        #expect(runCount == 2)
    }

    @Test("Cancel drops the queued pass; a later request still runs")
    @MainActor
    func cancelDropsQueuedPass() async {
        let clock = WindowClock()
        let coalescer = WorkspaceStatusAggregationCoalescer(sleep: { _ in await clock.sleep() })
        var parkedIterator = clock.parked.makeAsyncIterator()
        let (ran, ranContinuation) = AsyncStream<Int>.makeStream()
        var ranIterator = ran.makeAsyncIterator()

        var runCount = 0

        coalescer.schedule {
            runCount += 1
            ranContinuation.yield(1)
        }
        await parkedIterator.next()
        coalescer.cancel()
        await clock.release()

        // The cancelled pass must not run. Prove it positively: a fresh request runs
        // and observes only its own value — the dropped one left no trace.
        coalescer.schedule {
            runCount += 1
            ranContinuation.yield(2)
        }
        await parkedIterator.next()
        await clock.release()
        let observed = await ranIterator.next()

        #expect(observed == 2)
        #expect(runCount == 1)
    }
}
