//
//  BoardTimestamp.swift
//  WorkspaceManagerCore
//
//  The decision board's stamps come in two shapes and must be written in one.
//  The board page writes fractional seconds (2026-09-13T19:39:04.857Z) and the
//  card writer writes whole seconds (2026-09-13T04:32:45Z), so a reader that
//  accepts only one silently returns nothing for half the store — and a nil
//  `askedAt` fails no test, it just quietly reorders which decision interrupts
//  first.
//

import Foundation

public enum BoardTimestamp {
    /// Accepts both shapes the store actually holds.
    public static func read(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Built per call: ISO8601DateFormatter is not Sendable, and one
        // allocation is free beside the HTTP round trip that produced the string.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: trimmed)
    }

    /// Writes the shape the board page writes, because an answer from a tap has
    /// to be indistinguishable from an answer from a click.
    public static func write(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
