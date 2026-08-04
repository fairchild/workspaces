//
//  CommandMarkerParser.swift
//  WorkspaceManagerCore
//
//  Pure-function parser for OSC 133 "semantic prompt" escape sequences. This
//  is the shape libghostty would surface if/when it forwards FinalTerm/iTerm2
//  prompt marks to the application layer; until then, the parser is also
//  callable by any future shell-side producer (PROMPT hook script, PTY proxy,
//  etc.) that wants to emit the same byte protocol over its own transport.
//
//  Recognized markers:
//    ESC ] 133 ; A …          prompt start
//    ESC ] 133 ; B …          command start (about to execute)
//    ESC ] 133 ; C …          output start
//    ESC ] 133 ; D ; <exit>   command end with numeric exit status
//    ESC ] 133 ; D            command end with no exit status reported
//
//  All sequences may terminate with either BEL (0x07) or ST (ESC \).
//
//  Anything outside an OSC 133 introducer is ignored — this is not a general
//  ANSI parser. We tolerate fragmented input: an incomplete marker at the end
//  of a chunk is buffered and consumed when the next chunk arrives.
//

import Foundation

public enum CommandMarker: Equatable, Sendable {
    case promptStart
    case commandStart
    case outputStart
    case commandEnd(exitCode: Int?)
}

public struct CommandMarkerParser: Sendable {
    private var pending: Data = Data()
    private static let maxBufferedBytes = 4096

    public init() {}

    /// Feed a chunk of raw terminal bytes. Returns the markers found in order.
    /// Bytes that do not participate in a marker are discarded; markers split
    /// across chunks are reassembled across calls.
    public mutating func consume(_ chunk: Data) -> [CommandMarker] {
        var markers: [CommandMarker] = []
        var buffer = pending
        buffer.append(chunk)

        var index = buffer.startIndex
        var consumedThrough = buffer.startIndex

        while index < buffer.endIndex {
            // Look for ESC ] 133 ;  (5 bytes).
            guard let escIndex = Self.findIntroducer(in: buffer, from: index) else {
                // No complete introducer ahead. Check whether the tail of the
                // buffer looks like a partial introducer (ESC, ESC ], …) so we
                // hold those bytes for the next chunk; drop everything before
                // the partial prefix.
                let tailStart =
                    Self.partialIntroducerStart(in: buffer, from: index)
                    ?? buffer.endIndex
                consumedThrough = tailStart
                break
            }

            // Bytes before the introducer are not interesting.
            consumedThrough = escIndex

            let payloadStart = buffer.index(escIndex, offsetBy: Self.introducer.count)
            guard payloadStart < buffer.endIndex else {
                // Introducer present but payload not yet arrived.
                break
            }

            guard let terminatorRange = Self.findTerminator(in: buffer, from: payloadStart) else {
                // Wait for more bytes — but bail if the buffer is unbounded.
                if buffer.distance(from: escIndex, to: buffer.endIndex) > Self.maxBufferedBytes {
                    // Drop the runaway introducer to avoid unbounded growth.
                    consumedThrough = payloadStart
                }
                break
            }

            let payload = buffer.subdata(in: payloadStart..<terminatorRange.lowerBound)
            if let marker = Self.parsePayload(payload) {
                markers.append(marker)
            }
            consumedThrough = terminatorRange.upperBound
            index = terminatorRange.upperBound
        }

        if consumedThrough > buffer.startIndex {
            pending = buffer.subdata(in: consumedThrough..<buffer.endIndex)
        } else {
            pending = buffer
        }

        // Prevent unbounded growth if a malicious stream sends a perpetual
        // introducer without a terminator.
        if pending.count > Self.maxBufferedBytes {
            pending = pending.suffix(Self.maxBufferedBytes)
        }

        return markers
    }

    /// Convenience for callers that don't need cross-chunk state.
    public static func parse(_ chunk: Data) -> [CommandMarker] {
        var parser = CommandMarkerParser()
        return parser.consume(chunk)
    }

    // MARK: - Internals

    /// `ESC ] 1 3 3 ;` — five bytes.
    private static let introducer: [UInt8] = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B]

    /// Returns the index of the first byte of a prefix-match of `introducer`
    /// at the buffer tail (i.e. a partial introducer that may complete in a
    /// future chunk), or `nil` if no such prefix exists. Considers prefixes of
    /// length 1..<introducer.count.
    private static func partialIntroducerStart(in data: Data, from start: Data.Index) -> Data.Index? {
        let maxPrefix = min(introducer.count - 1, data.distance(from: start, to: data.endIndex))
        guard maxPrefix > 0 else { return nil }
        // Longest prefix wins.
        for prefixLen in stride(from: maxPrefix, through: 1, by: -1) {
            let candidate = data.index(data.endIndex, offsetBy: -prefixLen)
            var match = true
            for offset in 0..<prefixLen {
                if data[data.index(candidate, offsetBy: offset)] != introducer[offset] {
                    match = false
                    break
                }
            }
            if match { return candidate }
        }
        return nil
    }

    private static func findIntroducer(in data: Data, from start: Data.Index) -> Data.Index? {
        guard data.distance(from: start, to: data.endIndex) >= introducer.count else {
            return nil
        }
        var i = start
        let limit = data.index(data.endIndex, offsetBy: -(introducer.count - 1))
        while i < limit {
            if data[i] == introducer[0] {
                var match = true
                for offset in 1..<introducer.count {
                    if data[data.index(i, offsetBy: offset)] != introducer[offset] {
                        match = false
                        break
                    }
                }
                if match { return i }
            }
            i = data.index(after: i)
        }
        return nil
    }

    /// Locates the terminator (BEL or ST = ESC \) starting from `start`.
    /// Returns the range covering the terminator bytes themselves.
    private static func findTerminator(in data: Data, from start: Data.Index) -> Range<Data.Index>? {
        var i = start
        while i < data.endIndex {
            let byte = data[i]
            if byte == 0x07 {  // BEL
                return i..<data.index(after: i)
            }
            if byte == 0x1B {
                let next = data.index(after: i)
                if next < data.endIndex, data[next] == 0x5C {  // ESC \
                    return i..<data.index(after: next)
                }
                // A lone ESC inside an OSC payload is ambiguous; treat as
                // terminator boundary at ESC itself so we don't swallow the
                // following sequence.
                return i..<i
            }
            i = data.index(after: i)
        }
        return nil
    }

    private static func parsePayload(_ payload: Data) -> CommandMarker? {
        guard let string = String(data: payload, encoding: .utf8), !string.isEmpty else {
            return nil
        }
        // payload examples:
        //   "A"                  — prompt start
        //   "A;aid=xyz"          — prompt start with key=value tail
        //   "B"                  — command start
        //   "C"                  — output start
        //   "D"                  — command end, no exit code
        //   "D;0"                — command end, exit code 0
        //   "D;137;err=killed"   — command end, exit 137 plus tail
        // swift-format-ignore: NeverForceUnwrap
        // Safe: string is non-empty per the guard above.
        let marker = string.first!
        let tail = string.dropFirst()
        switch marker {
        case "A": return .promptStart
        case "B": return .commandStart
        case "C": return .outputStart
        case "D":
            guard tail.first == ";" else { return .commandEnd(exitCode: nil) }
            let afterSemi = tail.dropFirst()
            let code = afterSemi.prefix { $0 != ";" }
            if code.isEmpty { return .commandEnd(exitCode: nil) }
            return .commandEnd(exitCode: Int(code))
        default:
            return nil
        }
    }
}
