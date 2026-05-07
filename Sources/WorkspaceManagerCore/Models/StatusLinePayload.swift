//
//  StatusLinePayload.swift
//  WorkspaceManagerCore
//
//  Wire-format for the Claude Code status-line forwarder. The bundled
//  `Resources/HookForwarders/statusline.sh` script POSTs the JSON Claude Code
//  feeds it on stdin to the host's `/statusline` route. We decode tolerantly:
//  missing fields are nil, unknown keys are ignored.
//
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 2 ("Fields the host reads").
//

import Foundation

/// Tolerant decoder for the Claude Code status-line payload. The shape mirrors
/// the documented status-line JSON; every field is optional so future additions
/// don't break decode.
public struct StatusLinePayload: Sendable, Equatable {
    public let cwd: String?
    public let agentSessionID: String?
    public let model: Model?
    public let workspace: Workspace?
    public let cost: Cost?
    public let contextWindow: ContextWindow?
    public let rateLimits: RateLimits?
    public let outputStyle: OutputStyle?
    public let version: String?

    public init(
        cwd: String? = nil,
        agentSessionID: String? = nil,
        model: Model? = nil,
        workspace: Workspace? = nil,
        cost: Cost? = nil,
        contextWindow: ContextWindow? = nil,
        rateLimits: RateLimits? = nil,
        outputStyle: OutputStyle? = nil,
        version: String? = nil
    ) {
        self.cwd = cwd
        self.agentSessionID = agentSessionID
        self.model = model
        self.workspace = workspace
        self.cost = cost
        self.contextWindow = contextWindow
        self.rateLimits = rateLimits
        self.outputStyle = outputStyle
        self.version = version
    }

    public struct Model: Sendable, Equatable {
        public let id: String?
        public let displayName: String?
        public init(id: String? = nil, displayName: String? = nil) {
            self.id = id
            self.displayName = displayName
        }
    }

    public struct Workspace: Sendable, Equatable {
        public let currentDir: String?
        public let projectDir: String?
        public let gitWorktree: String?
        public init(
            currentDir: String? = nil,
            projectDir: String? = nil,
            gitWorktree: String? = nil
        ) {
            self.currentDir = currentDir
            self.projectDir = projectDir
            self.gitWorktree = gitWorktree
        }
    }

    public struct Cost: Sendable, Equatable {
        public let totalCostUSD: Double?
        public let totalLinesAdded: Int?
        public let totalLinesRemoved: Int?
        public init(
            totalCostUSD: Double? = nil,
            totalLinesAdded: Int? = nil,
            totalLinesRemoved: Int? = nil
        ) {
            self.totalCostUSD = totalCostUSD
            self.totalLinesAdded = totalLinesAdded
            self.totalLinesRemoved = totalLinesRemoved
        }
    }

    public struct ContextWindow: Sendable, Equatable {
        public let usedPercentage: Double?
        public let contextWindowSize: Int?
        public init(
            usedPercentage: Double? = nil,
            contextWindowSize: Int? = nil
        ) {
            self.usedPercentage = usedPercentage
            self.contextWindowSize = contextWindowSize
        }
    }

    public struct RateLimits: Sendable, Equatable {
        public let fiveHour: Window?
        public init(fiveHour: Window? = nil) { self.fiveHour = fiveHour }

        public struct Window: Sendable, Equatable {
            public let usedPercentage: Double?
            public let resetsAt: Date?
            public init(usedPercentage: Double? = nil, resetsAt: Date? = nil) {
                self.usedPercentage = usedPercentage
                self.resetsAt = resetsAt
            }
        }
    }

    public struct OutputStyle: Sendable, Equatable {
        public let name: String?
        public init(name: String? = nil) { self.name = name }
    }
}

extension StatusLinePayload {
    /// Decode tolerantly from raw JSON. Returns `nil` only when the body is not
    /// even a JSON object — every other shape (missing keys, unknown keys, type
    /// mismatches) decodes to a payload with the affected fields set to `nil`.
    public static func decode(from data: Data) -> StatusLinePayload? {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return StatusLinePayload(rawJSON: raw)
    }

    public init(rawJSON raw: [String: Any]) {
        self.cwd =
            (raw["cwd"] as? String)
            ?? (raw["working_directory"] as? String)
            ?? (raw["workingDirectory"] as? String)
            ?? (raw["workspace"] as? [String: Any]).flatMap {
                ($0["current_dir"] as? String) ?? ($0["currentDir"] as? String)
            }
        self.agentSessionID =
            (raw["session_id"] as? String)
            ?? (raw["sessionId"] as? String)
            ?? (raw["sessionID"] as? String)

        if let m = raw["model"] as? [String: Any] {
            self.model = Model(
                id: m["id"] as? String,
                displayName: (m["display_name"] as? String)
                    ?? (m["displayName"] as? String)
            )
        } else {
            self.model = nil
        }

        if let w = raw["workspace"] as? [String: Any] {
            self.workspace = Workspace(
                currentDir: (w["current_dir"] as? String)
                    ?? (w["currentDir"] as? String),
                projectDir: (w["project_dir"] as? String)
                    ?? (w["projectDir"] as? String),
                gitWorktree: (w["git_worktree"] as? String)
                    ?? (w["gitWorktree"] as? String)
            )
        } else {
            self.workspace = nil
        }

        if let c = raw["cost"] as? [String: Any] {
            self.cost = Cost(
                totalCostUSD: Self.double(c["total_cost_usd"] ?? c["totalCostUSD"]),
                totalLinesAdded: Self.int(c["total_lines_added"] ?? c["totalLinesAdded"]),
                totalLinesRemoved: Self.int(c["total_lines_removed"] ?? c["totalLinesRemoved"])
            )
        } else {
            self.cost = nil
        }

        if let cw = raw["context_window"] as? [String: Any] ?? raw["contextWindow"] as? [String: Any] {
            self.contextWindow = ContextWindow(
                usedPercentage: Self.double(cw["used_percentage"] ?? cw["usedPercentage"]),
                contextWindowSize: Self.int(cw["context_window_size"] ?? cw["contextWindowSize"])
            )
        } else {
            self.contextWindow = nil
        }

        if let rl = raw["rate_limits"] as? [String: Any] ?? raw["rateLimits"] as? [String: Any] {
            let fh = rl["five_hour"] as? [String: Any] ?? rl["fiveHour"] as? [String: Any]
            if let fh {
                self.rateLimits = RateLimits(
                    fiveHour: RateLimits.Window(
                        usedPercentage: Self.double(fh["used_percentage"] ?? fh["usedPercentage"]),
                        resetsAt: Self.date(fh["resets_at"] ?? fh["resetsAt"])
                    )
                )
            } else {
                self.rateLimits = RateLimits(fiveHour: nil)
            }
        } else {
            self.rateLimits = nil
        }

        if let os = raw["output_style"] as? [String: Any] ?? raw["outputStyle"] as? [String: Any] {
            self.outputStyle = OutputStyle(name: os["name"] as? String)
        } else {
            self.outputStyle = nil
        }

        self.version = raw["version"] as? String
    }

    /// Project the payload into the registry's normalized status fields. Hosts
    /// of the workspace prefer `workspace.current_dir` over the top-level `cwd`
    /// because Claude Code's status-line carries the workspace block.
    public func resolvedCwd() -> String? {
        if let v = workspace?.currentDir, !v.isEmpty { return v }
        if let v = cwd, !v.isEmpty { return v }
        return nil
    }

    public func toStatusFields() -> AgentEvent.StatusFields {
        AgentEvent.StatusFields(
            modelDisplayName: model?.displayName ?? model?.id,
            contextUsedPercent: contextWindow?.usedPercentage,
            fiveHourLimitUsedPercent: rateLimits?.fiveHour?.usedPercentage,
            fiveHourLimitResetsAt: rateLimits?.fiveHour?.resetsAt,
            costUSD: cost?.totalCostUSD
        )
    }

    // MARK: - Tolerant scalar coercion

    private static func double(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String { return Double(v) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? NSNumber { return v.intValue }
        if let v = value as? String { return Int(v) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let v = value as? Date { return v }
        if let v = value as? String, let d = Self.iso8601.date(from: v) { return d }
        if let v = value as? String, let d = Self.iso8601Fractional.date(from: v) { return d }
        if let v = value as? Double { return Date(timeIntervalSince1970: v) }
        if let v = value as? Int { return Date(timeIntervalSince1970: TimeInterval(v)) }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
