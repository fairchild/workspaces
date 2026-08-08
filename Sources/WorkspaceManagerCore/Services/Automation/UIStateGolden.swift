//
//  UIStateGolden.swift
//  WorkspaceManagerCore
//
//  Deterministic golden comparison for structural UI state. A golden document pins the
//  expected `AutomationUIStateSnapshot` JSON for one fixture scenario; `compare` is a
//  pure function producing path-sorted mismatches, so a failing diff names exactly what
//  moved. Goldens update only through the explicit update flow (scripts/ui-state-golden.sh
//  update) — never automatically on mismatch.
//

import Foundation

public enum UIStateGolden {
    /// One golden file under `fixtures/ui-state/<scenario>.json`. `ignore` lists dot
    /// paths pruned from both sides before comparison (arrays traverse element-wise),
    /// the extension point for fields that later prove machine-varying; the `volatile`
    /// wire subtree is already excluded by schema position and needs no entry here.
    public struct Document: Sendable, Equatable {
        public let scenario: String
        public let ignore: [String]
        public let state: JSONValue

        public init(scenario: String, ignore: [String], state: JSONValue) {
            self.scenario = scenario
            self.ignore = ignore
            self.state = state
        }
    }

    /// Minimal JSON tree with a bool/number distinction (`JSONSerialization` bridges
    /// both to `NSNumber`; `CFBoolean` type identity keeps `true` ≠ `1`).
    public indirect enum JSONValue: Sendable, Equatable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    /// One structural difference, addressed by a dot path (`sidebar[2].workspaces[0].name`).
    /// `expected`/`actual` are canonical compact JSON; `nil` marks an absent side.
    public struct Mismatch: Sendable, Equatable, CustomStringConvertible {
        public let path: String
        public let expected: String?
        public let actual: String?

        public init(path: String, expected: String?, actual: String?) {
            self.path = path
            self.expected = expected
            self.actual = actual
        }

        public var description: String {
            "\(path): expected \(expected ?? "<absent>"), actual \(actual ?? "<absent>")"
        }
    }

    public struct DecodeError: Error, Sendable, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: - Decoding

    public static func jsonValue(from data: Data) throws -> JSONValue {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DecodeError(message: "Not valid JSON: \(error.localizedDescription)")
        }
        return jsonValue(fromRaw: raw)
    }

    public static func jsonValue<Value: Encodable>(encoding value: Value) throws -> JSONValue {
        try jsonValue(from: JSONEncoder().encode(value))
    }

    public static func document(from data: Data) throws -> Document {
        guard case .object(let root) = try jsonValue(from: data) else {
            throw DecodeError(message: "Golden document must be a JSON object.")
        }
        guard case .string(let scenario)? = root["scenario"] else {
            throw DecodeError(message: "Golden document must carry a string 'scenario'.")
        }
        var ignore: [String] = []
        if let rawIgnore = root["ignore"] {
            guard case .array(let entries) = rawIgnore else {
                throw DecodeError(message: "Golden 'ignore' must be an array of dot paths.")
            }
            ignore = try entries.map { entry in
                guard case .string(let path) = entry else {
                    throw DecodeError(message: "Golden 'ignore' entries must be strings.")
                }
                return path
            }
        }
        guard let state = root["state"] else {
            throw DecodeError(message: "Golden document must carry a 'state' object.")
        }
        return Document(scenario: scenario, ignore: ignore, state: state)
    }

    // MARK: - Comparison

    /// Compares a golden document against an actual state tree. Both sides are pruned
    /// of the document's `ignore` paths first; the result is path-sorted and empty on
    /// match. Pure — same inputs, same output, no I/O.
    public static func compare(document: Document, actualState: JSONValue) -> [Mismatch] {
        let expected = prune(document.state, ignoring: document.ignore)
        let actual = prune(actualState, ignoring: document.ignore)
        var mismatches: [Mismatch] = []
        diff(expected: expected, actual: actual, path: "state", into: &mismatches)
        return mismatches.sorted { $0.path < $1.path }
    }

    /// Removes every `ignore` dot path from `value`. A path segment names an object
    /// key; arrays are traversed transparently, so `sidebar.workspaces.name` strips
    /// `name` from every row of every section.
    public static func prune(_ value: JSONValue, ignoring paths: [String]) -> JSONValue {
        paths.reduce(value) { pruned, path in
            let segments = path.split(separator: ".").map(String.init)
            guard !segments.isEmpty else { return pruned }
            return prune(pruned, segments: segments[...])
        }
    }

    /// Canonical compact rendering: object keys sorted, stable across processes.
    public static func canonical(_ value: JSONValue) -> String {
        switch value {
        case .object(let members):
            let body =
                members
                .sorted { $0.key < $1.key }
                .map { key, value in "\(escapeJSON(key)):\(canonical(value))" }
                .joined(separator: ",")
            return "{\(body)}"
        case .array(let elements):
            return "[\(elements.map(canonical).joined(separator: ","))]"
        case .string(let string):
            return escapeJSON(string)
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int64(number)) : String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    // MARK: - Internals

    private static func jsonValue(fromRaw raw: Any) -> JSONValue {
        switch raw {
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues { jsonValue(fromRaw: $0) })
        case let array as [Any]:
            return .array(array.map { jsonValue(fromRaw: $0) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        default:
            return .null
        }
    }

    private static func prune(_ value: JSONValue, segments: ArraySlice<String>) -> JSONValue {
        guard let key = segments.first else { return value }
        switch value {
        case .object(var members):
            if segments.count == 1 {
                members.removeValue(forKey: key)
            } else if let child = members[key] {
                members[key] = prune(child, segments: segments.dropFirst())
            }
            return .object(members)
        case .array(let elements):
            return .array(elements.map { prune($0, segments: segments) })
        default:
            return value
        }
    }

    private static func diff(
        expected: JSONValue,
        actual: JSONValue,
        path: String,
        into mismatches: inout [Mismatch]
    ) {
        switch (expected, actual) {
        case (.object(let expectedMembers), .object(let actualMembers)):
            for key in Set(expectedMembers.keys).union(actualMembers.keys).sorted() {
                let childPath = "\(path).\(key)"
                switch (expectedMembers[key], actualMembers[key]) {
                case (let expectedChild?, let actualChild?):
                    diff(expected: expectedChild, actual: actualChild, path: childPath, into: &mismatches)
                case (let expectedChild?, nil):
                    mismatches.append(
                        Mismatch(path: childPath, expected: canonical(expectedChild), actual: nil))
                case (nil, let actualChild?):
                    mismatches.append(
                        Mismatch(path: childPath, expected: nil, actual: canonical(actualChild)))
                case (nil, nil):
                    break
                }
            }
        case (.array(let expectedElements), .array(let actualElements)):
            if expectedElements.count != actualElements.count {
                mismatches.append(
                    Mismatch(
                        path: "\(path).count",
                        expected: String(expectedElements.count),
                        actual: String(actualElements.count)
                    ))
            }
            for (index, pair) in zip(expectedElements, actualElements).enumerated() {
                diff(expected: pair.0, actual: pair.1, path: "\(path)[\(index)]", into: &mismatches)
            }
        default:
            if expected != actual {
                mismatches.append(
                    Mismatch(path: path, expected: canonical(expected), actual: canonical(actual)))
            }
        }
    }

    private static func escapeJSON(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(string)\""
    }
}
