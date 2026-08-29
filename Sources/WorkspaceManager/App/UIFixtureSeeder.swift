//
//  UIFixtureSeeder.swift
//  WorkspaceManager
//
//  Fixture-mode seeding for SwiftData, agent session state, and command status.
//  Drives deterministic screenshots via WORKSPACES_UI_FIXTURE_* env vars.
//

#if DEBUG
    import AppKit
    import Foundation
    import SwiftData
    import WorkspaceManagerCore
    import os.log

    private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "UIFixtureSeeder")

    @MainActor
    enum UIFixtureSeeder {
        static let agentStatesEnvKey = "WORKSPACES_UI_FIXTURE_AGENT_STATES"
        static let commandStatusesEnvKey = "WORKSPACES_UI_FIXTURE_COMMAND_STATUSES"
        static let pinnedEnvKey = "WORKSPACES_UI_FIXTURE_PINNED"
        static let archivedEnvKey = "WORKSPACES_UI_FIXTURE_ARCHIVED"

        /// Idempotency latch — `seedAgentStatesIfNeeded` may be invoked multiple times
        /// as views re-appear, but the synthetic events should only land once per launch.
        static var hasSeededAgentStates = false
        static var hasSeededCommandStatuses = false

        /// Seeds the in-memory fixture model context with the standard set of repos,
        /// web sources, and workspaces used across screenshots. No-op when the context
        /// already has repos. Workspace access dates are spread relative to `now` so the
        /// Recent arrangement renders all three of its buckets.
        static func seedDataIfNeeded(in context: ModelContext, now: Date = Date()) {
            do {
                let repoCount = try context.fetchCount(FetchDescriptor<Repo>())
                guard repoCount == 0 else { return }
            } catch {
                // If readback fails, continue and try to seed once.
            }

            let codeRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("code", isDirectory: true)
            let workspacesRoot = codeRoot.appendingPathComponent("workspaces", isDirectory: true)

            let skillsRepo = Repo(
                name: "skills",
                localPath: codeRoot.appendingPathComponent("skills", isDirectory: true)
            )
            let servicesRepo = Repo(
                name: "services",
                localPath: codeRoot.appendingPathComponent("services", isDirectory: true)
            )
            let superpowersRepo = Repo(
                name: "superpowers",
                localPath: codeRoot.appendingPathComponent("superpowers", isDirectory: true)
            )
            let workspacesRepo = Repo(
                name: "workspaces",
                localPath: codeRoot.appendingPathComponent("workspaces", isDirectory: true)
            )
            let bertramChatRepo = Repo(
                name: "bertram-chat",
                localPath: codeRoot.appendingPathComponent("bertram-chat", isDirectory: true)
            )
            let breadBuilderRepo = Repo(
                name: "bread-builder",
                localPath: codeRoot.appendingPathComponent("bread-builder", isDirectory: true)
            )
            let swiftDocs = WebSource(
                name: "Swift Docs",
                baseURLString: "https://docs.swift.org/",
                allowedHost: "docs.swift.org"
            )

            context.insert(skillsRepo)
            context.insert(servicesRepo)
            context.insert(superpowersRepo)
            context.insert(workspacesRepo)
            context.insert(bertramChatRepo)
            context.insert(breadBuilderRepo)
            context.insert(swiftDocs)

            let thisWeek = now.addingTimeInterval(-3 * 24 * 60 * 60)
            let earlier = now.addingTimeInterval(-30 * 24 * 60 * 60)

            let skillsWorkspace = Workspace(
                name: "skills-v13",
                path: workspacesRoot.appendingPathComponent("skills/skills-v13", isDirectory: true),
                sourceRepo: skillsRepo,
                lastAccessedAt: thisWeek,
                gitBranch: "workspace/skills-v13"
            )
            context.insert(skillsWorkspace)

            // Bump feature-auth so the auto-selection (fallbackSurface) picks it on
            // launch — matches the design mockup at .context/ux-review/release-screenshot.png.
            let featureAuthWorkspace = Workspace(
                name: "feature-auth",
                path: workspacesRoot.appendingPathComponent("bertram-chat/feature-auth", isDirectory: true),
                sourceRepo: bertramChatRepo,
                lastAccessedAt: now.addingTimeInterval(60),
                gitBranch: "workspace/feature-auth"
            )
            let bugfix422Workspace = Workspace(
                name: "bugfix-422",
                path: workspacesRoot.appendingPathComponent("bertram-chat/bugfix-422", isDirectory: true),
                sourceRepo: bertramChatRepo,
                lastAccessedAt: earlier,
                gitBranch: "workspace/bugfix-422"
            )
            let refactorStateWorkspace = Workspace(
                name: "refactor-state",
                path: workspacesRoot.appendingPathComponent("bertram-chat/refactor-state", isDirectory: true),
                sourceRepo: bertramChatRepo,
                lastAccessedAt: thisWeek,
                gitBranch: "workspace/refactor-state"
            )
            context.insert(featureAuthWorkspace)
            context.insert(bugfix422Workspace)
            context.insert(refactorStateWorkspace)

            let refactorRuntimeWorkspace = Workspace(
                name: "refactor-runtime",
                path: workspacesRoot.appendingPathComponent("bread-builder/refactor-runtime", isDirectory: true),
                sourceRepo: breadBuilderRepo,
                lastAccessedAt: earlier,
                gitBranch: "workspace/refactor-runtime"
            )
            context.insert(refactorRuntimeWorkspace)

            do {
                try context.save()
            } catch {
                log.error("[UIFixture] Failed to seed fixture data: \(String(describing: error), privacy: .public)")
            }
        }

        /// Reads `WORKSPACES_UI_FIXTURE_PINNED` — a comma-separated workspace-name list —
        /// and pins those workspaces in listed order, so a capture renders the sidebar's
        /// Pinned section whatever the stored data holds. Parsed only in fixture mode, and
        /// only in debug builds (this whole file is `#if DEBUG`). Unknown names are logged
        /// and skipped rather than failing the launch. Returns how many were pinned.
        @discardableResult
        static func seedPinnedWorkspacesIfNeeded(
            from environment: [String: String],
            in context: ModelContext
        ) -> Int {
            let names = workspaceNames(from: environment, key: pinnedEnvKey)
            guard !names.isEmpty else { return 0 }

            let workspaces = fetchAllWorkspaces(in: context)
            var pinnedCount = 0
            for name in names {
                guard let workspace = workspace(named: name, in: workspaces, verb: "pin") else { continue }
                workspace.pinOrder = pinnedCount
                pinnedCount += 1
            }

            guard pinnedCount > 0 else { return 0 }

            do {
                try context.save()
            } catch {
                log.error(
                    "[UIFixture] Failed to seed pinned workspaces: \(String(describing: error), privacy: .public)")
            }
            return pinnedCount
        }

        /// Reads `WORKSPACES_UI_FIXTURE_ARCHIVED` — a comma-separated workspace-name list —
        /// and archives those workspaces, so a capture renders a repo's archived section
        /// whatever the stored data holds. Writes what `SidebarWorkspaceController.archive`
        /// writes to the record — the status, the timestamp the purge sweep reads, and the
        /// unpin that takes the row out of the Pinned shortcut list — but moves no directory:
        /// fixture paths are synthetic, and the sidebar reads the record, not the disk.
        /// Runs after the pinned seeder for the same reason archiving unpins in the app.
        /// Unknown names are logged and skipped. Returns how many were archived.
        @discardableResult
        static func seedArchivedWorkspacesIfNeeded(
            from environment: [String: String],
            in context: ModelContext,
            now: Date = Date()
        ) -> Int {
            let names = workspaceNames(from: environment, key: archivedEnvKey)
            guard !names.isEmpty else { return 0 }

            let workspaces = fetchAllWorkspaces(in: context)
            let pinController = SidebarPinController()
            var archivedCount = 0
            for name in names {
                guard let workspace = workspace(named: name, in: workspaces, verb: "archive") else { continue }
                workspace.status = .archived
                workspace.archivedAt = now
                pinController.unpin(workspace, in: workspaces)
                archivedCount += 1
            }

            guard archivedCount > 0 else { return 0 }

            do {
                try context.save()
            } catch {
                log.error(
                    "[UIFixture] Failed to seed archived workspaces: \(String(describing: error), privacy: .public)")
            }
            return archivedCount
        }

        /// The workspace names a name-list env var carries, or none when fixture mode is off
        /// or the value is blank. Fixture mode is checked here rather than at each call site:
        /// these vars name real records and mutate them, so they stay inert against a
        /// production store even in a debug build.
        private static func workspaceNames(
            from environment: [String: String],
            key: String
        ) -> [String] {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1",
                let raw = environment[key]
            else {
                return []
            }
            return
                raw
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        private static func workspace(
            named name: String,
            in workspaces: [Workspace],
            verb: String
        ) -> Workspace? {
            guard
                let workspace = workspaces.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                })
            else {
                log.error(
                    "[UIFixture] No fixture workspace named '\(name, privacy: .public)' to \(verb, privacy: .public) — skipping"
                )
                return nil
            }
            return workspace
        }

        /// Reads `WORKSPACES_UI_FIXTURE_AGENT_STATES`, resolves workspace names against
        /// `context`, ensures a `HostTerminalSession` exists for each, then applies
        /// synthetic agent events so the registry lands at the requested
        /// `AgentRunState`. Invalid entries log via `Logger` and are skipped.
        ///
        /// Best-effort: never throws, never crashes. Returns the number of workspace
        /// states applied successfully (useful for tests).
        @discardableResult
        static func seedAgentStatesIfNeeded(
            from environment: [String: String],
            in context: ModelContext,
            registry: AgentSessionRegistry,
            tileTreeStore: TileTreeStore
        ) -> Int {
            guard !hasSeededAgentStates else { return 0 }
            guard let raw = environment[agentStatesEnvKey],
                !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                return 0
            }
            hasSeededAgentStates = true

            let entries = parseEntries(raw)
            guard !entries.isEmpty else { return 0 }

            var applied = 0
            var firstActivation: (key: HostTerminalSessionKey, directory: URL)?
            let workspaces = fetchAllWorkspaces(in: context)
            for entry in entries {
                guard
                    let workspace = workspaces.first(where: {
                        $0.name.caseInsensitiveCompare(entry.workspaceName) == .orderedSame
                    })
                else {
                    log.error(
                        "[UIFixture] No fixture workspace named '\(entry.workspaceName, privacy: .public)' — skipping")
                    continue
                }

                let directory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
                let key: HostTerminalSessionKey = .hostPath(directory.path)
                let result = tileTreeStore.activateSession(key: key, directory: directory)
                if firstActivation == nil {
                    firstActivation = (key, directory)
                }
                let events = events(for: entry.run)
                if !events.isEmpty {
                    registry.apply(events: events, for: result.session.id, origin: .hook)
                }
                applied += 1
            }

            // Re-activate the first env-var entry so it ends up as the front tab. Treat the
            // first listed workspace as the canonical "selected" one for screenshots — natural
            // reading order, no extra syntax.
            if let primary = firstActivation {
                tileTreeStore.activateSession(key: primary.key, directory: primary.directory)
            }
            return applied
        }

        /// Reads `WORKSPACES_UI_FIXTURE_COMMAND_STATUSES`, resolves workspace names
        /// against `context`, ensures a host terminal session exists for each, then
        /// publishes synthetic command status for the M6 status sliver.
        @discardableResult
        static func seedCommandStatusesIfNeeded(
            from environment: [String: String],
            in context: ModelContext,
            commandStatusRegistry: LastCommandStatusRegistry,
            tileTreeStore: TileTreeStore,
            now: Date = Date()
        ) -> Int {
            guard !hasSeededCommandStatuses else { return 0 }
            guard let raw = environment[commandStatusesEnvKey],
                !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                return 0
            }
            hasSeededCommandStatuses = true

            let entries = parseCommandStatusEntries(raw)
            guard !entries.isEmpty else { return 0 }

            var applied = 0
            var firstActivation: (key: HostTerminalSessionKey, directory: URL)?
            let workspaces = fetchAllWorkspaces(in: context)
            for entry in entries {
                guard
                    let workspace = workspaces.first(where: {
                        $0.name.caseInsensitiveCompare(entry.workspaceName) == .orderedSame
                    })
                else {
                    log.error(
                        "[UIFixture] No fixture workspace named '\(entry.workspaceName, privacy: .public)' — skipping")
                    continue
                }

                let directory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
                let key: HostTerminalSessionKey = .hostPath(directory.path)
                let result = tileTreeStore.activateSession(key: key, directory: directory)
                if firstActivation == nil {
                    firstActivation = (key, directory)
                }
                commandStatusRegistry.setStatus(
                    entry.status.status(at: now),
                    for: result.session.id
                )
                applied += 1
            }

            if let primary = firstActivation {
                tileTreeStore.activateSession(key: primary.key, directory: primary.directory)
            }
            return applied
        }

        /// Test seam — resets the idempotency latch.
        static func resetForTesting() {
            hasSeededAgentStates = false
            hasSeededCommandStatuses = false
        }

        // MARK: - Parsing

        struct ParsedEntry: Equatable {
            let workspaceName: String
            let run: AgentRunState
        }

        static func parseEntries(_ raw: String) -> [ParsedEntry] {
            raw.split(separator: ",", omittingEmptySubsequences: true).compactMap { fragment in
                let pair = fragment.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else {
                    log.error(
                        "[UIFixture] Malformed agent-state entry '\(String(fragment), privacy: .public)' — expected name:state"
                    )
                    return nil
                }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                let stateToken = pair[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    log.error("[UIFixture] Empty workspace name in '\(String(fragment), privacy: .public)' — skipping")
                    return nil
                }
                guard let run = runState(for: stateToken) else {
                    log.error(
                        "[UIFixture] Unknown agent state '\(stateToken, privacy: .public)' for '\(name, privacy: .public)' — skipping"
                    )
                    return nil
                }
                return ParsedEntry(workspaceName: name, run: run)
            }
        }

        struct ParsedCommandStatusEntry: Equatable {
            let workspaceName: String
            let status: FixtureCommandStatus
        }

        enum FixtureCommandStatus: Equatable {
            case success
            case failed
            case running
            case finished

            func status(at now: Date) -> LastCommandStatus {
                switch self {
                case .success:
                    return LastCommandStatus(
                        commandLine: "swift build",
                        exitCode: 0,
                        startedAt: now.addingTimeInterval(-1.2),
                        endedAt: now
                    )
                case .failed:
                    return LastCommandStatus(
                        commandLine: "swift test",
                        exitCode: 1,
                        startedAt: now.addingTimeInterval(-2.4),
                        endedAt: now
                    )
                case .running:
                    return .started(commandLine: "swift test", at: now.addingTimeInterval(-8))
                case .finished:
                    return LastCommandStatus(
                        commandLine: "git status",
                        exitCode: nil,
                        startedAt: now.addingTimeInterval(-0.4),
                        endedAt: now
                    )
                }
            }
        }

        static func parseCommandStatusEntries(_ raw: String) -> [ParsedCommandStatusEntry] {
            raw.split(separator: ",", omittingEmptySubsequences: true).compactMap { fragment in
                let pair = fragment.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else {
                    log.error(
                        "[UIFixture] Malformed command-status entry '\(String(fragment), privacy: .public)' — expected name:status"
                    )
                    return nil
                }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                let stateToken = pair[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    log.error("[UIFixture] Empty workspace name in '\(String(fragment), privacy: .public)' — skipping")
                    return nil
                }
                guard let status = commandStatus(for: stateToken) else {
                    log.error(
                        "[UIFixture] Unknown command status '\(stateToken, privacy: .public)' for '\(name, privacy: .public)' — skipping"
                    )
                    return nil
                }
                return ParsedCommandStatusEntry(workspaceName: name, status: status)
            }
        }

        private static func runState(for token: String) -> AgentRunState? {
            switch token.lowercased() {
            case "idle": return .idle
            case "thinking": return .thinking
            case "runningtool", "running-tool": return .runningTool(name: "Edit", detail: "Models.swift")
            case "awaitinginput", "awaiting-input", "awaiting": return .awaitingInput(reason: .permissionPrompt)
            case "errored", "error": return .errored(category: .toolFailure, message: "Tool failed")
            case "complete": return .complete
            default: return nil
            }
        }

        /// Synthetic event list that drives the registry into the requested run state.
        /// Mirrors how `AgentSessionRegistry.apply` translates real events.
        private static func events(for run: AgentRunState) -> [AgentEvent] {
            switch run {
            case .idle:
                return []
            case .thinking:
                return [.userPrompt(prompt: nil)]
            case .runningTool(let name, let detail):
                return [.toolStart(name: name, detail: detail)]
            case .awaitingInput(let reason):
                return [.awaitingInput(reason: reason, title: nil, message: nil)]
            case .errored(let category, let message):
                return [.errored(category: category, message: message)]
            case .complete:
                return [.stopped(error: nil)]
            }
        }

        private static func commandStatus(for token: String) -> FixtureCommandStatus? {
            switch token.lowercased() {
            case "success", "succeeded", "exit0", "exit-0":
                return .success
            case "failed", "failure", "exit1", "exit-1", "nonzero", "non-zero":
                return .failed
            case "running", "inflight", "in-flight":
                return .running
            case "finished", "unknown", "unknown-exit":
                return .finished
            default:
                return nil
            }
        }

        private static func fetchAllWorkspaces(in context: ModelContext) -> [Workspace] {
            do {
                return try context.fetch(FetchDescriptor<Workspace>())
            } catch {
                log.error("[UIFixture] Could not fetch workspaces: \(String(describing: error), privacy: .public)")
                return []
            }
        }
    }
#endif
