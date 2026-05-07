//
//  TranscriptReader.swift
//  WorkspaceManagerCore
//
//  Streaming reader for Claude Code transcript JSONL files.
//
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 4. Two consumption shapes:
//
//    - `tail()`: opens the file, yields every record from the start, then ends.
//      Cold-start state recovery uses this. The throttle (≤500 ev/s) is applied
//      at the *consumer* (cold-start replay coordinator), not in the reader —
//      keeping the reader pure and reusable.
//
//    - `live()`: opens the file, yields existing records, then keeps the file
//      open for `tail -f`–style append polling. Real Claude does not push
//      faster than the listener handles, so this stream is uncapped.
//
//  Implementation notes:
//
//    - We poll on append (250 ms by default) rather than using Dispatch sources:
//      this makes the actor portable and side-effect free; transcripts are
//      append-only and the polling cost is trivial vs. the cold path.
//
//    - We hold a partial-line buffer across reads so JSONL records that span
//      file-read boundaries decode correctly.
//
//    - Unknown record types decode to `.opaque`; we never throw on a single
//      malformed line.
//

import Foundation

public actor TranscriptReader {
    public enum Error: Swift.Error, Sendable {
        case fileNotFound
    }

    private let transcriptPath: URL
    /// Polling interval for live-tail mode.
    private let pollInterval: TimeInterval

    public init(transcriptPath: URL, pollInterval: TimeInterval = 0.25) {
        self.transcriptPath = transcriptPath
        self.pollInterval = pollInterval
    }

    /// One-shot read of the existing transcript contents. Yields records in
    /// file order and finishes when EOF is reached. Used by cold-start replay.
    public nonisolated func tail() -> AsyncStream<TranscriptRecord> {
        AsyncStream { continuation in
            let task = Task.detached { [transcriptPath] in
                do {
                    try Self.readAll(from: transcriptPath) { record in
                        continuation.yield(record)
                    }
                } catch {
                    // Treat file-not-found and read errors as empty transcripts.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Live `tail -f` reader. Yields existing records, then polls for appends
    /// at `pollInterval` until the consumer cancels the stream.
    public nonisolated func live() -> AsyncStream<TranscriptRecord> {
        AsyncStream { continuation in
            let interval = self.pollInterval
            let path = self.transcriptPath
            let task = Task.detached {
                var offset: UInt64 = 0
                var pending = Data()
                while !Task.isCancelled {
                    let advanced = Self.readAppend(
                        from: path,
                        startingAt: &offset,
                        pending: &pending
                    ) { record in
                        continuation.yield(record)
                    }
                    if !advanced {
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internal

    private static func readAll(
        from url: URL,
        emit: (TranscriptRecord) -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            pending.append(chunk)
            emitLines(buffer: &pending, isFinal: false, emit: emit)
        }
        emitLines(buffer: &pending, isFinal: true, emit: emit)
    }

    /// Returns `true` if any new bytes were read. Maintains the file offset and
    /// the partial-line buffer across calls.
    private static func readAppend(
        from url: URL,
        startingAt offset: inout UInt64,
        pending: inout Data,
        emit: (TranscriptRecord) -> Void
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return false
        }
        var advanced = false
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            advanced = true
            offset += UInt64(chunk.count)
            pending.append(chunk)
            emitLines(buffer: &pending, isFinal: false, emit: emit)
        }
        return advanced
    }

    private static func emitLines(
        buffer: inout Data,
        isFinal: Bool,
        emit: (TranscriptRecord) -> Void
    ) {
        let newline: UInt8 = 0x0A
        while let nl = buffer.firstIndex(of: newline) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let record = TranscriptDecoder.decode(line: line) {
                emit(record)
            }
        }
        if isFinal && !buffer.isEmpty {
            if let record = TranscriptDecoder.decode(line: buffer) {
                emit(record)
            }
            buffer.removeAll()
        }
    }
}
