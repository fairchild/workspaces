//
//  WorkspaceClaudeSetup.swift
//  WorkspaceManagerCore
//
//  Post-`setup.sh` warm-up using `HeadlessClaudeRunner`. Channel 5
//  integration point: when a workspace ships a `.workspaces/claude-setup.json`
//  (or the app's `Resources/Defaults/claude-setup.json` falls in), we run
//  one non-interactive `claude -p` pass to seed the workspace (e.g. install
//  pre-commit hooks, drop a project README into the cwd, run a lint sweep).
//
//  Failure here NEVER fails workspace creation — we log + carry on. The
//  user expects a working workspace; the warm-up is bonus.
//

import Foundation
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceClaudeSetup"
)

/// Schema for both `Resources/Defaults/claude-setup.json` (app-shipped fallback)
/// and per-project `.workspaces/claude-setup.json`. The per-project file always
/// wins when present.
public struct ClaudeSetupConfig: Codable, Sendable, Equatable {
    public let prompt: String
    public let allowedTools: [String]?
    public let resume: Bool?

    public init(prompt: String, allowedTools: [String]? = nil, resume: Bool? = nil) {
        self.prompt = prompt
        self.allowedTools = allowedTools
        self.resume = resume
    }
}

public enum WorkspaceClaudeSetup {
    /// Look up a `claude-setup.json` for a given workspace. Per-project
    /// (`.workspaces/claude-setup.json`) takes precedence; app default (under
    /// `Resources/Defaults/claude-setup.json` in the running bundle) is the
    /// fallback. Returns `nil` if neither is present or if the file is
    /// malformed (we log + skip rather than fail the workspace creation).
    public static func loadConfig(
        for workspaceDir: URL,
        appDefaultsLookup: () -> URL? = appDefaultsLookup
    ) -> ClaudeSetupConfig? {
        let projectURL =
            workspaceDir
            .appendingPathComponent(".workspaces", isDirectory: true)
            .appendingPathComponent("claude-setup.json")
        if let config = decode(at: projectURL) {
            return config
        }
        if let bundleURL = appDefaultsLookup(), let config = decode(at: bundleURL) {
            return config
        }
        return nil
    }

    /// Default app-bundle lookup. Splittable for tests.
    public static let appDefaultsLookup: () -> URL? = {
        Bundle.main.url(forResource: "claude-setup", withExtension: "json")
    }

    /// Run the warm-up. Streams events into `eventSink`. Catches all errors
    /// and logs them — never throws. Returns the captured `session_id` for
    /// resume, when present.
    @discardableResult
    public static func runWarmup(
        config: ClaudeSetupConfig,
        in workspaceDir: URL,
        runner: HeadlessClaudeRunner,
        sessionStore: HeadlessSessionStore? = nil,
        eventSink: @Sendable (HeadlessClaudeEvent) -> Void = { _ in }
    ) async -> String? {
        let store = sessionStore ?? HeadlessSessionStore(workspaceRoot: workspaceDir)
        let resume = (config.resume ?? false) ? store.loadLatestSessionID() : nil
        let stream = await runner.run(
            prompt: config.prompt,
            cwd: workspaceDir,
            allowedTools: config.allowedTools ?? [],
            resumeSessionID: resume
        )

        var capturedSessionID: String?
        for await event in stream {
            eventSink(event)
            if case .result(_, _, _, _, let sessionID) = event,
                let sessionID, !sessionID.isEmpty
            {
                capturedSessionID = sessionID
            }
        }

        if let capturedSessionID {
            do {
                try store.recordSessionID(capturedSessionID)
            } catch {
                log.warning(
                    "failed to persist headless claude session id: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return capturedSessionID
    }

    private static func decode(at url: URL) -> ClaudeSetupConfig? {
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ClaudeSetupConfig.self, from: data)
        } catch {
            log.warning(
                "ignoring malformed claude-setup.json at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
