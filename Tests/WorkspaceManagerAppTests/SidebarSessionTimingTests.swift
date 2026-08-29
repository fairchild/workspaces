import Foundation
import Testing

@testable import WorkspaceManager

@Suite("Sidebar session timing")
struct SidebarSessionTimingTests {
    @Test(
        "Elapsed time reads mm:ss under an hour and h:mm:ss from an hour on",
        arguments: [
            (0, "00:00"),
            (1, "00:01"),
            (59, "00:59"),
            (60, "01:00"),
            (61, "01:01"),
            (599, "09:59"),
            (600, "10:00"),
            (3_599, "59:59"),
            (3_600, "1:00:00"),
            (3_661, "1:01:01"),
            (35_999, "9:59:59"),
            (36_000, "10:00:00"),
            (359_999, "99:59:59"),
        ] as [(Int, String)]
    )
    func formatsElapsed(seconds: Int, expected: String) {
        #expect(SessionElapsedFormatter.text(elapsed: seconds) == expected)
    }

    /// A session whose start sits ahead of the clock reading it — a system clock corrected
    /// backwards after the session registered — shows a stopped timer rather than a countdown.
    @Test("A start ahead of now clamps to zero", arguments: [-1, -59, -3_600, -86_400])
    func clampsFutureStart(seconds: Int) {
        #expect(SessionElapsedFormatter.text(elapsed: seconds) == "00:00")
    }

    @Test("Elapsed time is measured between the two dates it is given")
    func formatsElapsedBetweenDates() {
        let started = Date(timeIntervalSince1970: 1_756_000_000)
        #expect(SessionElapsedFormatter.text(from: started, to: started) == "00:00")
        #expect(
            SessionElapsedFormatter.text(from: started, to: started.addingTimeInterval(452))
                == "07:32"
        )
        #expect(
            SessionElapsedFormatter.text(from: started, to: started.addingTimeInterval(3_782))
                == "1:03:02"
        )
        // Part-seconds belong to the second that has not finished elapsing.
        #expect(
            SessionElapsedFormatter.text(from: started, to: started.addingTimeInterval(59.9))
                == "00:59"
        )
        #expect(
            SessionElapsedFormatter.text(from: started, to: started.addingTimeInterval(-30))
                == "00:00"
        )
    }

    @Test(
        "Age reads as one unit, coarsening as it grows",
        arguments: [
            (0, "0m"),
            (59, "0m"),
            (60, "1m"),
            (3_540, "59m"),
            (3_600, "1h"),
            (86_399, "23h"),
            (86_400, "1d"),
            (450_000, "5d"),
            (364 * 86_400, "364d"),
            (365 * 86_400, "1y"),
            (800 * 86_400, "2y"),
        ] as [(Int, String)]
    )
    func formatsAge(seconds: Int, expected: String) {
        #expect(WorkspaceAgeFormatter.text(age: seconds) == expected)
    }

    @Test("A workspace created in the future is zero minutes old, not negative")
    func clampsFutureCreation() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        #expect(WorkspaceAgeFormatter.text(from: now.addingTimeInterval(600), to: now) == "0m")
    }

    @Test("Age is measured between the two dates it is given")
    func formatsAgeBetweenDates() {
        let created = Date(timeIntervalSince1970: 1_756_000_000)
        #expect(
            WorkspaceAgeFormatter.text(from: created, to: created.addingTimeInterval(5 * 86_400))
                == "5d"
        )
        #expect(
            WorkspaceAgeFormatter.text(from: created, to: created.addingTimeInterval(3 * 3_600))
                == "3h"
        )
    }
}
