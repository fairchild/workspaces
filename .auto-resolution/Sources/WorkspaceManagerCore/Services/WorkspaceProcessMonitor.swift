//
//  WorkspaceProcessMonitor.swift
//  WorkspaceManagerCore
//
//  Detects processes running in workspace directories via lsof CWD matching.
//

import Foundation

public actor WorkspaceProcessMonitor: WorkspaceProcessMonitorProtocol {
    public struct DetectedProcess: Sendable, Equatable, Codable {
        public let displayName: String
        public let isKnownAgent: Bool

        public init(displayName: String, isKnownAgent: Bool) {
            self.displayName = displayName
            self.isKnownAgent = isKnownAgent
        }
    }

    public struct AgentStatus: Sendable, Equatable {
        public let processes: [DetectedProcess]

        public var isAgentRunning: Bool { processes.contains { $0.isKnownAgent } }
        public var agentName: String? { processes.first { $0.isKnownAgent }?.displayName }
        public var processCount: Int { processes.count }

        public init(processes: [DetectedProcess]) {
            self.processes = processes
        }

        public static let inactive = AgentStatus(processes: [])
    }

    private struct ProcessInfo {
        let pid: Int
        let command: String
        let cwd: String
    }

    private static let knownAgents: [(displayName: String, patterns: [String])] = [
        ("Claude", ["/claude", " claude ", "claude-agent"]),
        ("Pi", ["/pi ", "/pi-", "pi-acp", " pi "]),
        ("Cursor", ["/cursor", " cursor "]),
        ("Aider", ["/aider", " aider "]),
        ("Codex", ["/codex", " codex "]),
    ]

    private static let ignoredCommands: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "login", "sshd", "ssh-agent",
        "workspacemanager", "ghostty", "lsof", "ps", "grep", "cat", "ls",
        "git", "ssh", "env", "direnv",
    ]

    public init() {}

    public func detectAgents(in workspaceDirectories: [UUID: URL]) async -> [UUID: AgentStatus] {
        async let processes = fetchProcessCWDs()
        async let fullCommands = fetchFullCommands()
        let (resolvedProcesses, resolvedFullCommands) = await (processes, fullCommands)
        var results: [UUID: AgentStatus] = [:]
        for (id, directory) in workspaceDirectories {
            results[id] = matchProcesses(
                processes: resolvedProcesses,
                fullCommands: resolvedFullCommands,
                workspacePath: directory.path
            )
        }
        return results
    }

    public func detectAgentSession(in workspaceDirectory: URL) async -> AgentStatus {
        async let processes = fetchProcessCWDs()
        async let fullCommands = fetchFullCommands()
        return matchProcesses(
            processes: await processes,
            fullCommands: await fullCommands,
            workspacePath: workspaceDirectory.path
        )
    }

    // MARK: - Process Discovery

    /// Parse `lsof -d cwd -F pcn` for (pid, command, cwd) tuples.
    private func fetchProcessCWDs() async -> [ProcessInfo] {
        guard
            let output = await runProcess(
                "/usr/bin/lsof", arguments: ["-d", "cwd", "-F", "pcn"]
            )
        else { return [] }

        var results: [ProcessInfo] = []
        var currentPID: Int?
        var currentCommand: String?

        for line in output.components(separatedBy: "\n") {
            guard !line.isEmpty else { continue }
            // Safe: line is non-empty per the guard above
            let prefix = line.first!
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                currentPID = Int(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            case "n":
                if let pid = currentPID, let cmd = currentCommand {
                    results.append(ProcessInfo(pid: pid, command: cmd, cwd: value))
                }
            default:
                break
            }
        }
        return results
    }

    /// Parse `ps -eo pid=,args=` for PID → full command line.
    private func fetchFullCommands() async -> [Int: String] {
        guard
            let output = await runProcess(
                "/bin/ps", arguments: ["-eo", "pid=,args="]
            )
        else { return [:] }

        var map: [Int: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            map[pid] = String(parts[1])
        }
        return map
    }

    // MARK: - Matching

    private func matchProcesses(
        processes: [ProcessInfo],
        fullCommands: [Int: String],
        workspacePath: String
    ) -> AgentStatus {
        var detected: [DetectedProcess] = []
        var seenNames: Set<String> = []
        // Normalize: strip trailing slash for exact match, add it for prefix match
        let cleanPath = workspacePath.hasSuffix("/") ? String(workspacePath.dropLast()) : workspacePath
        let prefixPath = cleanPath + "/"

        for proc in processes {
            guard proc.cwd == cleanPath || proc.cwd.hasPrefix(prefixPath) else { continue }

            let fullArgs = fullCommands[proc.pid] ?? ""
            // Pad with spaces so word-boundary patterns like " pi " match at edges
            let searchable = " " + proc.command + " " + fullArgs + " "

            // Check known agents first
            var matched = false
            for (displayName, patterns) in Self.knownAgents {
                if patterns.contains(where: { searchable.contains($0) }) {
                    if seenNames.insert(displayName).inserted {
                        detected.append(DetectedProcess(displayName: displayName, isKnownAgent: true))
                    }
                    matched = true
                    break
                }
            }

            if !matched {
                let cmdName = Self.extractCommandName(command: proc.command, fullArgs: fullArgs)
                guard !Self.ignoredCommands.contains(cmdName.lowercased()) else { continue }
                if seenNames.insert(cmdName.lowercased()).inserted {
                    detected.append(DetectedProcess(displayName: cmdName, isKnownAgent: false))
                }
            }
        }

        // Known agents first, then others; tie-break by name for deterministic ordering.
        return AgentStatus(
            processes: detected.sorted { lhs, rhs in
                if lhs.isKnownAgent != rhs.isKnownAgent {
                    return lhs.isKnownAgent && !rhs.isKnownAgent
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
        )
    }

    /// Extract a readable command name from lsof command + ps args.
    static func extractCommandName(command: String, fullArgs: String) -> String {
        // Try to get binary name from full args first (more reliable than lsof truncation).
        // If the full args look like a path-based command, extract the binary name.
        // We check if command appears as a basename anywhere in the first path-like segment.
        guard !fullArgs.isEmpty else { return command }

        // Find the executable path: scan for the first argument that looks like a path
        // containing the command name, handling paths with spaces.
        if let range = fullArgs.range(of: command) {
            // Walk backwards from the match to find the path start (/ or beginning)
            let before = fullArgs[fullArgs.startIndex..<range.lowerBound]
            if let slashIdx = before.lastIndex(of: "/") {
                // Extract from the last slash to end of the command name
                let pathStart = before[slashIdx...]
                let fullName = String(pathStart) + command
                let name = URL(fileURLWithPath: fullName).lastPathComponent
                if !name.isEmpty { return name }
            }
            return command
        }

        // Fallback: first whitespace-delimited token as path
        if let firstToken = fullArgs.split(separator: " ").first {
            let name = URL(fileURLWithPath: String(firstToken)).lastPathComponent
            if !name.isEmpty { return name }
        }
        return command
    }

    private func runProcess(_ path: String, arguments: [String]) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
