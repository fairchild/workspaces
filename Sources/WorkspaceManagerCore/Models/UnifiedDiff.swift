//
//  UnifiedDiff.swift
//  WorkspaceManagerCore
//
//  Structured representation of a single-file unified diff.
//

import Foundation

public struct UnifiedDiff: Equatable, Sendable {
    public let path: String
    public let oldPath: String?
    public let hunks: [Hunk]
    public let addedLines: Int
    public let removedLines: Int

    public init(path: String, oldPath: String? = nil, hunks: [Hunk]) {
        self.path = path
        self.oldPath = oldPath
        self.hunks = hunks
        self.addedLines = hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
        self.removedLines = hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
    }

    public struct Hunk: Equatable, Sendable {
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [Line]) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.lines = lines
        }
    }

    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable {
            case context
            case added
            case removed
        }

        public let kind: Kind
        public let content: String

        public init(kind: Kind, content: String) {
            self.kind = kind
            self.content = content
        }
    }

    public enum ParseError: LocalizedError {
        case malformedHunkHeader(String)

        public var errorDescription: String? {
            switch self {
            case .malformedHunkHeader(let header):
                return "Malformed hunk header: \(header)"
            }
        }
    }

    /// Parse the output of `git diff --no-color <file>` for a single file.
    public static func parse(_ raw: String, path: String) throws -> UnifiedDiff {
        var oldPath: String? = nil
        var hunks: [Hunk] = []

        var currentHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? = nil
        var currentLines: [Line] = []

        func flushHunk() {
            guard let h = currentHeader else { return }
            hunks.append(
                Hunk(
                    oldStart: h.oldStart,
                    oldCount: h.oldCount,
                    newStart: h.newStart,
                    newCount: h.newCount,
                    lines: currentLines
                )
            )
            currentHeader = nil
            currentLines = []
        }

        let rawLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in rawLines {
            // File headers (before any hunk)
            if currentHeader == nil {
                if line.hasPrefix("rename from ") {
                    oldPath = String(line.dropFirst("rename from ".count))
                    continue
                }
                if line.hasPrefix("--- a/") {
                    let candidate = String(line.dropFirst("--- a/".count))
                    if candidate != path, oldPath == nil {
                        oldPath = candidate
                    }
                    continue
                }
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("diff --git")
                    || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                    || line.hasPrefix("similarity ") || line.hasPrefix("rename to ")
                {
                    continue
                }
            }

            if line.hasPrefix("@@") {
                flushHunk()
                currentHeader = try parseHunkHeader(line)
                continue
            }

            guard currentHeader != nil else {
                continue
            }

            if line.hasPrefix("+") {
                currentLines.append(Line(kind: .added, content: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                currentLines.append(Line(kind: .removed, content: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                currentLines.append(Line(kind: .context, content: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — ignore.
                continue
            } else if line.isEmpty {
                // Empty line within a hunk is a context line with empty content.
                currentLines.append(Line(kind: .context, content: ""))
            }
        }

        flushHunk()

        return UnifiedDiff(path: path, oldPath: oldPath, hunks: hunks)
    }

    private static func parseHunkHeader(
        _ header: String
    ) throws -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        // Format: @@ -oldStart[,oldCount] +newStart[,newCount] @@ optional-context
        guard let openRange = header.range(of: "@@"),
            let closeRange = header.range(of: "@@", range: openRange.upperBound..<header.endIndex)
        else {
            throw ParseError.malformedHunkHeader(header)
        }
        let inner = header[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)

        let parts = inner.split(separator: " ")
        guard parts.count == 2 else {
            throw ParseError.malformedHunkHeader(header)
        }
        let old = String(parts[0])
        let new = String(parts[1])
        guard old.hasPrefix("-"), new.hasPrefix("+") else {
            throw ParseError.malformedHunkHeader(header)
        }

        let (oldStart, oldCount) = try parseRange(String(old.dropFirst()), header: header)
        let (newStart, newCount) = try parseRange(String(new.dropFirst()), header: header)
        return (oldStart, oldCount, newStart, newCount)
    }

    private static func parseRange(_ spec: String, header: String) throws -> (Int, Int) {
        let parts = spec.split(separator: ",")
        guard let start = Int(parts[0]) else {
            throw ParseError.malformedHunkHeader(header)
        }
        if parts.count == 1 {
            return (start, 1)
        }
        guard parts.count == 2, let count = Int(parts[1]) else {
            throw ParseError.malformedHunkHeader(header)
        }
        return (start, count)
    }
}
