//
//  main.swift
//  WorkspaceManagerCLI
//

import AppKit
import Darwin
import Foundation
import WorkspaceManagerCore

@main
struct WorkspaceManagerCLI {
    static func main() async {
        let app = CLIApp()
        do {
            let exitCode = try await app.run(arguments: Array(CommandLine.arguments.dropFirst()))
            Darwin.exit(exitCode)
        } catch {
            writeStderr("error: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }
}

private final class CLIApp {
    private static let appBundleIdentifier = "com.cloudcompute.workspaces"
    private static let reservedCommands = CLIVerbCatalog.reservedCommands

    private let stateStore = CLIStateStore()
    private let workspaceService: WorkspaceService = .shared
    private let gitService: GitService = .shared

    func run(arguments: [String]) async throws -> Int32 {
        guard arguments.first != nil else {
            return try await launchApp(request: nil)
        }

        if let launchRequest = try appLaunchRequest(for: arguments) {
            return try await launchApp(request: launchRequest)
        }

        // Top-level automation aliases ('workspaces workspace list') canonicalize into the
        // grouped form ('workspaces automation workspace list') before dispatch, so both
        // spellings share one code path. Canonicalization only ever prepends, so the
        // non-empty guarantee from the guard above carries through it.
        let canonical = CLIVerbCatalog.canonicalArguments(arguments)
        precondition(!canonical.isEmpty, "canonicalArguments emptied a non-empty argument vector")
        let command = canonical[0]

        var state = try stateStore.load()
        let tail = Array(canonical.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printHelp()
            return 0
        case "repo":
            return try await runRepo(arguments: tail, state: &state)
        case "ws":
            return try await runWorkspace(arguments: tail, state: &state)
        case "open":
            return try await runOpen(arguments: tail, state: &state)
        case "run":
            return try await runRun(arguments: tail, state: &state)
        case "resume":
            return try await runResume(state: &state)
        case "status":
            return try await runStatus(arguments: tail, state: &state)
        case "recent":
            return runRecent(state: state)
        case "doctor":
            return try await runDoctor(state: state)
        case "automation":
            return try runAutomation(arguments: tail)
        default:
            throw CLIError("Unknown command '\(command)'. Run 'workspaces help'.")
        }
    }

    private func appLaunchRequest(for arguments: [String]) throws -> AppLaunchRequest? {
        guard arguments.count == 1 else { return nil }
        guard let rawArgument = arguments.first else { return nil }
        // Reserved verbs win over path-like arguments so `workspaces doctor`
        // always dispatches to the subcommand even if a sibling folder exists.
        guard !Self.reservedCommands.contains(rawArgument) else { return nil }
        guard looksLikePath(rawArgument) || fileSystemEntryExists(at: rawArgument) else { return nil }

        let resolvedURL = normalizePath(rawArgument)
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory)
        guard exists else {
            throw CLIError("Path not found: \(rawArgument)")
        }

        let launchDirectory =
            isDirectory.boolValue
            ? resolvedURL
            : resolvedURL.deletingLastPathComponent()
        return try AppLaunchRequest(launchDirectory: launchDirectory)
    }

    private func looksLikePath(_ argument: String) -> Bool {
        argument == "."
            || argument == ".."
            || argument.hasPrefix("./")
            || argument.hasPrefix("../")
            || argument.hasPrefix("/")
            || argument.hasPrefix("~")
    }

    private func fileSystemEntryExists(at rawPath: String) -> Bool {
        FileManager.default.fileExists(atPath: normalizePath(rawPath).path)
    }

    private func launchApp(request: AppLaunchRequest?) async throws -> Int32 {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier)
        else {
            throw CLIError(
                "Could not find the WorkSpaces app. Install it first so the 'workspaces' launcher can hand off to the GUI."
            )
        }

        if let request {
            let deepLinkURL = request.deepLinkURL
            guard NSWorkspace.shared.open(deepLinkURL) else {
                throw CLIError("Failed to open WorkSpaces for path: \(request.launchDirectory.path)")
            }
            return 0
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await openApplication(at: appURL, configuration: configuration)

        return 0
    }

    private func runRepo(arguments: [String], state: inout CLIState) async throws -> Int32 {
        guard let subcommand = arguments.first else {
            throw CLIError("Missing repo subcommand. Expected: add, list")
        }

        switch subcommand {
        case "add":
            guard arguments.count >= 2 else {
                throw CLIError("Usage: workspaces repo add <path>")
            }
            let repoURL = normalizePath(arguments[1])
            try validateGitRepository(at: repoURL)

            if let existingIndex = state.repos.firstIndex(where: { $0.path == repoURL.path }) {
                let existing = state.repos[existingIndex]
                print("Repository already tracked: \(existing.name) (\(existing.path))")
                return 0
            }

            let repo = RepoRecord(
                id: UUID(),
                name: repoURL.lastPathComponent,
                path: repoURL.path,
                addedAt: Date()
            )
            state.repos.append(repo)
            try stateStore.save(state)
            print("Added repository: \(repo.name)")
            print(repo.path)
            if let inventory = appInventory(),
                let notice = CLIPlaneComposer.repoAddNotice(app: inventory, addedRepoPath: repo.path)
            {
                writeStderr(notice)
            }
            return 0

        case "list":
            let localRows = state.repos
                .sorted(by: { $0.addedAt > $1.addedAt })
                .map { CLIPlaneComposer.LocalRow(displayName: $0.name, path: $0.path) }
            for line in CLIPlaneComposer.repoListLines(app: appInventory(), local: localRows) {
                print(line)
            }
            return 0

        default:
            throw CLIError("Unknown repo subcommand '\(subcommand)'. Expected: add, list")
        }
    }

    private func runWorkspace(arguments: [String], state: inout CLIState) async throws -> Int32 {
        guard let subcommand = arguments.first else {
            throw CLIError("Missing ws subcommand. Expected: new, list, path, race")
        }

        switch subcommand {
        case "new":
            guard arguments.count >= 3 else {
                throw CLIError("Usage: workspaces ws new <repo> <name>")
            }

            let repoToken = arguments[1]
            let workspaceName = arguments.dropFirst(2).joined(separator: " ").trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !workspaceName.isEmpty else {
                throw CLIError("Workspace name cannot be empty.")
            }

            let repo = try resolveLocalRepoOrExplain(token: repoToken, state: state)

            let info = try await workspaceService.createWorkspace(
                repoName: repo.name,
                repoLocalURL: URL(fileURLWithPath: repo.path),
                name: workspaceName
            )

            let localConfig = loadWorkspaceLocalConfig(at: info.path)
            let workspace = WorkspaceRecord(
                id: UUID(),
                name: info.name,
                repoName: repo.name,
                repoPath: repo.path,
                path: info.path.path,
                gitBranch: info.gitBranch,
                createdAt: Date(),
                lastAccessedAt: Date(),
                defaultCommand: localConfig.defaultCommand
            )

            state.workspaces.removeAll { $0.path == workspace.path }
            state.workspaces.append(workspace)
            try stateStore.save(state)

            print("Created workspace: \(workspaceDisplayName(workspace))")
            print("Path: \(workspace.path)")
            print("Branch: \(workspace.gitBranch)")
            return 0

        case "list":
            let localRows = state.workspaces
                .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
                .map { CLIPlaneComposer.LocalRow(displayName: workspaceDisplayName($0), path: $0.path) }
            for line in CLIPlaneComposer.workspaceListLines(app: appInventory(), local: localRows) {
                print(line)
            }
            return 0

        case "path":
            guard arguments.count >= 2 else {
                throw CLIError("Usage: workspaces ws path <workspace>")
            }
            let workspace = try resolveWorkspace(token: arguments[1], state: &state)
            print(workspace.path)
            return 0

        case "race":
            return try await runWorkspaceRace(arguments: Array(arguments.dropFirst()), state: &state)

        default:
            throw CLIError("Unknown ws subcommand '\(subcommand)'. Expected: new, list, path, race")
        }
    }

    /// Fans one prompt across N fresh worktree workspaces and launches a detached headless
    /// agent (`<cmd> -p '<prompt>'`) in each. Fail-fast: a failure at workspace k keeps
    /// workspaces 1..k-1 (recoverable via `ws list`) and reports what was created.
    private func runWorkspaceRace(arguments: [String], state: inout CLIState) async throws -> Int32 {
        let usage = "workspaces ws race <repo> <prompt...> [--n 3] [--cmd \"claude\"] [--name <slug>] [--no-launch]"

        var repoToken: String?
        var promptWords: [String] = []
        var count = 3
        var command = "claude"
        var nameOverride: String?
        var launch = true

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--n":
                index += 1
                guard index < arguments.count, let parsed = Int(arguments[index]) else {
                    throw CLIError("Missing or invalid value for --n")
                }
                count = parsed
            case "--cmd":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("Missing value for --cmd")
                }
                command = arguments[index]
            case "--name":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("Missing value for --name")
                }
                nameOverride = arguments[index]
            case "--no-launch":
                launch = false
            default:
                if repoToken == nil {
                    repoToken = token
                } else {
                    promptWords.append(token)
                }
            }
            index += 1
        }

        guard let repoToken else {
            throw CLIError("Usage: \(usage)")
        }
        let prompt = promptWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw CLIError("Usage: \(usage)")
        }
        guard RaceGroupPlanner.countRange.contains(count) else {
            let range = RaceGroupPlanner.countRange
            throw CLIError("--n must be between \(range.lowerBound) and \(range.upperBound).")
        }
        let repo = try resolveLocalRepoOrExplain(token: repoToken, state: state)

        let plan = RaceGroupPlanner.plan(
            prompt: prompt,
            count: count,
            command: command,
            nameOverride: nameOverride
        )

        var createdWorkspaces: [WorkspaceRecord] = []
        var failure: (name: String, error: Error)?
        for name in plan.workspaceNames {
            do {
                let info = try await workspaceService.createWorkspace(
                    repoName: repo.name,
                    repoLocalURL: URL(fileURLWithPath: repo.path),
                    name: name
                )
                createdWorkspaces.append(
                    WorkspaceRecord(
                        id: UUID(),
                        name: info.name,
                        repoName: repo.name,
                        repoPath: repo.path,
                        path: info.path.path,
                        gitBranch: info.gitBranch,
                        createdAt: Date(),
                        lastAccessedAt: Date(),
                        defaultCommand: command
                    )
                )
            } catch {
                failure = (name, error)
                break
            }
        }

        for workspace in createdWorkspaces {
            state.workspaces.removeAll { $0.path == workspace.path }
            state.workspaces.append(workspace)
        }

        if !createdWorkspaces.isEmpty {
            var record = RaceGroupRecord(
                id: UUID(),
                slug: plan.slug,
                repoName: repo.name,
                prompt: prompt,
                command: command,
                workspaceIDs: createdWorkspaces.map(\.id),
                createdAt: Date(),
                agentPIDs: []
            )
            if launch {
                for workspace in createdWorkspaces {
                    if let pid = spawnDetachedAgent(
                        command: plan.agentCommand,
                        workspaceURL: URL(fileURLWithPath: workspace.path)
                    ) {
                        record.agentPIDs.append(pid)
                    }
                }
            }
            var groups = state.raceGroups ?? []
            groups.append(record)
            state.raceGroups = groups
        }
        try stateStore.save(state)

        for workspace in createdWorkspaces {
            print("Created workspace: \(workspaceDisplayName(workspace))")
            print("  Path: \(workspace.path)")
            print("  Branch: \(workspace.gitBranch)")
            if launch {
                print("  Log: \(workspace.path)/\(Self.raceAgentLogName)")
            }
            print("  Attach: workspaces open \(workspace.repoName)/\(workspace.name)")
        }

        if let failure {
            writeStderr("error: failed to create workspace '\(failure.name)': \(failure.error.localizedDescription)")
            let progress = "\(createdWorkspaces.count) of \(plan.workspaceNames.count)"
            writeStderr("Created \(progress) workspaces before failing; see 'workspaces ws list'.")
            return 1
        }
        return 0
    }

    private static let raceAgentLogName = ".race-agent.log"

    /// Launches the agent as a detached child (no waitUntilExit) with output captured to
    /// the workspace's race log. Returns the PID, or nil when launch fails (recorded as a
    /// warning; the workspace itself stays usable via `workspaces open`).
    private func spawnDetachedAgent(command: String, workspaceURL: URL) -> Int32? {
        let logURL = workspaceURL.appendingPathComponent(Self.raceAgentLogName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            writeStderr("warning: could not open \(logURL.path) for agent output; skipping launch")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workspaceURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            writeStderr("warning: failed to launch agent in \(workspaceURL.path): \(error.localizedDescription)")
            return nil
        }
        return process.processIdentifier
    }

    private func runOpen(arguments: [String], state: inout CLIState) async throws -> Int32 {
        guard !arguments.isEmpty else {
            throw CLIError("Usage: workspaces open <workspace> [--cmd \"command\"]")
        }

        var workspaceToken: String?
        var commandOverride: String?

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--cmd" {
                index += 1
                guard index < arguments.count else {
                    throw CLIError("Missing value for --cmd")
                }
                commandOverride = arguments[index]
            } else if workspaceToken == nil {
                workspaceToken = token
            } else {
                throw CLIError("Unexpected argument: \(token)")
            }
            index += 1
        }

        guard let workspaceToken else {
            throw CLIError("Usage: workspaces open <workspace> [--cmd \"command\"]")
        }

        var workspace = try resolveWorkspace(token: workspaceToken, state: &state)
        let workspaceURL = URL(fileURLWithPath: workspace.path)
        let config = loadWorkspaceLocalConfig(at: workspaceURL)
        let command = commandOverride ?? workspace.defaultCommand ?? config.defaultCommand

        if workspace.defaultCommand == nil, let defaultCommand = config.defaultCommand {
            workspace.defaultCommand = defaultCommand
            updateWorkspace(workspace, state: &state)
        }

        markWorkspaceAccess(workspaceID: workspace.id, command: command, state: &state)
        try stateStore.save(state)

        return try runInteractiveSession(in: workspaceURL, command: command)
    }

    private func runRun(arguments: [String], state: inout CLIState) async throws -> Int32 {
        guard arguments.count >= 3 else {
            throw CLIError("Usage: workspaces run <workspace> -- <command...>")
        }

        let workspaceToken = arguments[0]
        let workspace = try resolveWorkspace(token: workspaceToken, state: &state)
        let workspaceURL = URL(fileURLWithPath: workspace.path)

        let commandString: String
        let execution: ProcessExecutionResult

        if arguments.count >= 3, arguments[1] == "--cmd" {
            let shellCommand = arguments.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !shellCommand.isEmpty else {
                throw CLIError("Missing command for --cmd")
            }
            commandString = shellCommand
            execution = try runCapturedCommand(
                executable: "/bin/zsh",
                arguments: ["-lc", shellCommand],
                currentDirectory: workspaceURL
            )
        } else {
            guard let separator = arguments.firstIndex(of: "--") else {
                throw CLIError("Usage: workspaces run <workspace> -- <command...>")
            }
            let commandParts = Array(arguments.dropFirst(separator + 1))
            guard !commandParts.isEmpty else {
                throw CLIError("Missing command after '--'")
            }

            let executable = try resolveExecutable(commandParts[0])
            let executableArgs = Array(commandParts.dropFirst())
            commandString = commandParts.joined(separator: " ")

            execution = try runCapturedCommand(
                executable: executable,
                arguments: executableArgs,
                currentDirectory: workspaceURL
            )
        }

        if !execution.stdout.isEmpty {
            print(execution.stdout, terminator: execution.stdout.hasSuffix("\n") ? "" : "\n")
        }
        if !execution.stderr.isEmpty {
            writeStderr(execution.stderr)
        }

        markWorkspaceAccess(workspaceID: workspace.id, command: commandString, state: &state)
        try stateStore.save(state)
        return execution.exitCode
    }

    private func runResume(state: inout CLIState) async throws -> Int32 {
        guard let lastSession = state.lastSession else {
            throw CLIError("No previous session found. Use 'workspaces open <workspace>' first.")
        }

        guard var workspace = state.workspaces.first(where: { $0.id == lastSession.workspaceID }) else {
            throw CLIError("Last workspace is no longer tracked. Use 'workspaces ws list'.")
        }

        let workspaceURL = URL(fileURLWithPath: workspace.path)
        let config = loadWorkspaceLocalConfig(at: workspaceURL)
        let command = lastSession.command ?? workspace.defaultCommand ?? config.defaultCommand

        if workspace.defaultCommand == nil, let defaultCommand = config.defaultCommand {
            workspace.defaultCommand = defaultCommand
            updateWorkspace(workspace, state: &state)
        }

        markWorkspaceAccess(workspaceID: workspace.id, command: command, state: &state)
        try stateStore.save(state)

        return try runInteractiveSession(in: workspaceURL, command: command)
    }

    private func runStatus(arguments: [String], state: inout CLIState) async throws -> Int32 {
        guard !arguments.isEmpty else {
            throw CLIError("Usage: workspaces status <workspace> [--watch] [--interval <seconds>]")
        }

        var workspaceToken: String?
        var watch = false
        var intervalSeconds = 2.0

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--watch":
                watch = true
            case "--interval":
                index += 1
                guard index < arguments.count else {
                    throw CLIError("Missing value for --interval")
                }
                guard let parsed = Double(arguments[index]), parsed > 0 else {
                    throw CLIError("Invalid interval: \(arguments[index])")
                }
                intervalSeconds = parsed
            default:
                if workspaceToken == nil {
                    workspaceToken = token
                } else {
                    throw CLIError("Unexpected argument: \(token)")
                }
            }
            index += 1
        }

        guard let workspaceToken else {
            throw CLIError("Usage: workspaces status <workspace> [--watch] [--interval <seconds>]")
        }

        let workspace = try resolveWorkspace(token: workspaceToken, state: &state)
        let workspaceURL = URL(fileURLWithPath: workspace.path)

        repeat {
            try await printGitStatus(for: workspace, workspaceURL: workspaceURL)
            if !watch { break }
            try await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            print("")
        } while true

        return 0
    }

    private func runRecent(state: CLIState) -> Int32 {
        guard !state.recents.isEmpty else {
            print("No recent sessions.")
            return 0
        }

        let formatter = ISO8601DateFormatter()
        for item in state.recents {
            guard let workspace = state.workspaces.first(where: { $0.id == item.workspaceID }) else {
                continue
            }
            let commandText = item.command ?? "(interactive shell)"
            print("\(formatter.string(from: item.openedAt))\t\(workspaceDisplayName(workspace))\t\(commandText)")
        }
        return 0
    }

    private func runDoctor(state: CLIState) async throws -> Int32 {
        var failures = 0

        func report(_ name: String, _ ok: Bool, _ details: String) {
            let marker = ok ? "OK" : "FAIL"
            print("[\(marker)] \(name): \(details)")
            if !ok {
                failures += 1
            }
        }

        do {
            let gitPath = try resolveExecutable("git")
            report("git", true, gitPath)
        } catch {
            report("git", false, "not found on PATH")
        }

        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        report(
            "shell",
            FileManager.default.isExecutableFile(atPath: shellPath),
            shellPath
        )

        let stateDirectory = CLIPaths.configDirectory
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let probe = stateDirectory.appendingPathComponent(".write-test-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            report("state-dir", true, stateDirectory.path)
        } catch {
            report("state-dir", false, "not writable: \(stateDirectory.path)")
        }

        let root = await workspaceService.workspacesRoot
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        report("workspaces-root", exists && isDirectory.boolValue, root.path)

        print("[INFO] tracked repos: \(state.repos.count)")
        print("[INFO] tracked workspaces: \(state.workspaces.count)")
        return failures == 0 ? 0 : 1
    }

    /// `workspaces automation <verb>` — the namespace grouping every verb that talks to
    /// the app's automation socket. The five gesture/read verbs also keep their historical
    /// top-level spellings as aliases (canonicalized in `run` before dispatch).
    private func runAutomation(arguments: [String]) throws -> Int32 {
        let expected = "health, context, surface, tile, input, window, workspace"
        guard let subcommand = arguments.first else {
            throw CLIError("Missing automation subcommand. Expected: \(expected)")
        }
        let tail = Array(arguments.dropFirst())

        switch subcommand {
        case "health":
            let result = try performAutomationHealthRequest()
            if tail.contains("--json") {
                print(try AutomationCLIResultPrinter.resultJSON(result))
            } else {
                print(Self.healthLine(result))
            }
            return 0

        case "context":
            let json = try requireJSONFlag(
                arguments: tail, usage: "workspaces automation context --json")
            let result: AutomationContextResult = try performAutomationRequest(
                method: "GET",
                path: "/v1/context",
                requiresHandle: true
            )
            if json {
                print(try AutomationCLIResultPrinter.resultJSON(result))
            }
            return 0

        case "surface":
            return try runSurface(arguments: tail)
        case "tile":
            return try runTile(arguments: tail)
        case "input":
            return try runInput(arguments: tail)
        case "window":
            return try runWindow(arguments: tail)
        case "workspace":
            return try runWorkspaceOperator(arguments: tail)

        default:
            throw CLIError("Unknown automation subcommand '\(subcommand)'. Expected: \(expected)")
        }
    }

    private func runSurface(arguments: [String]) throws -> Int32 {
        guard arguments.first == "list" else {
            throw CLIError("Usage: workspaces automation surface list --json")
        }
        let json = try requireJSONFlag(
            arguments: Array(arguments.dropFirst()), usage: "workspaces automation surface list --json")
        let result: AutomationSurfacesResult = try performAutomationRequest(
            method: "GET",
            path: "/v1/surfaces",
            requiresHandle: true
        )
        if json {
            print(try AutomationCLIResultPrinter.resultJSON(result))
        }
        return 0
    }

    private func runTile(arguments: [String]) throws -> Int32 {
        guard let subcommand = arguments.first else {
            throw CLIError("Missing tile subcommand. Expected: focus, split, close")
        }
        let tail = Array(arguments.dropFirst())

        switch subcommand {
        case "focus":
            let direction = try singleDirectionFlag(
                AutomationTileFocusDirection.self,
                arguments: tail,
                usage: "workspaces automation tile focus --left|--right|--up|--down|--next|--previous"
            )
            let body = try directionBody(direction.rawValue)
            _ = try performAutomationRequest(
                AutomationMutationResult.self,
                method: "POST",
                path: "/v1/tile/focus",
                requiresHandle: true,
                body: body
            )
            return 0

        case "split":
            let direction = try singleDirectionFlag(
                AutomationTileSplitDirection.self,
                arguments: tail,
                usage: "workspaces automation tile split --left|--right|--up|--down"
            )
            let body = try directionBody(direction.rawValue)
            _ = try performAutomationRequest(
                AutomationMutationResult.self,
                method: "POST",
                path: "/v1/tile/split",
                requiresHandle: true,
                body: body
            )
            return 0

        case "close":
            guard tail.isEmpty else {
                throw CLIError("Usage: workspaces automation tile close")
            }
            _ = try performAutomationRequest(
                AutomationMutationResult.self,
                method: "POST",
                path: "/v1/tile/close",
                requiresHandle: true
            )
            return 0

        default:
            throw CLIError("Unknown tile subcommand '\(subcommand)'. Expected: focus, split, close")
        }
    }

    private func runInput(arguments: [String]) throws -> Int32 {
        let usage = "workspaces automation input write <text> [--submit]"
        guard arguments.first == "write" else {
            throw CLIError("Usage: \(usage)")
        }

        var text: String?
        var submit = false
        for argument in arguments.dropFirst() {
            switch argument {
            case "--submit":
                submit = true
            default:
                guard text == nil else {
                    throw CLIError("Usage: \(usage)")
                }
                text = argument
            }
        }
        guard let text, !text.isEmpty else {
            throw CLIError("Usage: \(usage)")
        }

        let body = try JSONSerialization.data(
            withJSONObject: ["text": text, "submit": submit] as [String: Any],
            options: [.sortedKeys]
        )
        _ = try performAutomationRequest(
            AutomationInputWriteResult.self,
            method: "POST",
            path: "/v1/input/write",
            requiresHandle: true,
            body: body
        )
        return 0
    }

    /// `workspaces automation window <list|snapshot>` — the operator-scope commands. Unlike the tile-scoped
    /// commands, they read the per-launch operator credential file (minted next to the socket by an
    /// opted-in launch) rather than the `WORKSPACES_AUTOMATION_HANDLE` env, so they work from any
    /// same-user shell outside a WorkSpaces tile. Absent the credential they fail closed with guidance.
    private func runWindow(arguments: [String]) throws -> Int32 {
        switch arguments.first {
        case "list":
            return try runWindowList(arguments: Array(arguments.dropFirst()))
        case "snapshot":
            return try runWindowSnapshot(arguments: Array(arguments.dropFirst()))
        default:
            throw CLIError(
                "Usage: workspaces automation window list [--json] | window snapshot --out <path> [--window <id>]")
        }
    }

    private func runWindowList(arguments: [String]) throws -> Int32 {
        let usage = "workspaces automation window list [--json]"
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            default:
                throw CLIError("Usage: \(usage)")
            }
        }

        let credential = try loadOperatorCredential()
        let result = try operatorRequest(
            AutomationWindowsResult.self,
            credential: credential,
            method: "GET",
            path: "/v1/windows",
            body: Data()
        )

        if json {
            print(try AutomationCLIResultPrinter.resultJSON(result))
            return 0
        }

        if result.windows.isEmpty {
            print("No windows.")
            return 0
        }
        for window in result.windows {
            let title = window.title.isEmpty ? "(untitled)" : window.title
            let size = "\(Int(window.width))x\(Int(window.height))"
            print("\(window.windowID)\t\(size)\t\(title)")
        }
        return 0
    }

    /// `workspaces automation window snapshot --out <path> [--window <id>]` — writes a composited PNG of an app
    /// window (operator scope). With no `--window`, it targets the main window (falling back to the
    /// first listed), so the common "snapshot the app" case needs no id lookup. Works with the app
    /// backgrounded — no activation, no focus steal.
    private func runWindowSnapshot(arguments: [String]) throws -> Int32 {
        let usage = "workspaces automation window snapshot --out <path> [--window <id>]"
        var outPath: String?
        var windowID: String?

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --out") }
                outPath = arguments[index]
            case "--window":
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for --window") }
                windowID = arguments[index]
            default:
                throw CLIError("Usage: \(usage)")
            }
            index += 1
        }

        guard let outPath, !outPath.isEmpty else {
            throw CLIError("Usage: \(usage)")
        }

        let credential = try loadOperatorCredential()

        let targetWindowID: String
        if let windowID {
            targetWindowID = windowID
        } else {
            let windows = try operatorRequest(
                AutomationWindowsResult.self,
                credential: credential,
                method: "GET",
                path: "/v1/windows",
                body: Data()
            )
            guard
                let target = windows.windows.first(where: { $0.isMain }) ?? windows.windows.first
            else {
                throw CLIError("No capturable WorkSpaces window is open.")
            }
            targetWindowID = target.windowID
        }

        let body = try JSONSerialization.data(
            withJSONObject: ["windowID": targetWindowID],
            options: [.sortedKeys]
        )
        let result = try operatorRequest(
            AutomationWindowSnapshotResult.self,
            credential: credential,
            method: "POST",
            path: "/v1/window/snapshot",
            body: body
        )
        guard let pngData = Data(base64Encoded: result.data) else {
            throw CLIError("Snapshot response was not decodable PNG data.")
        }
        let outURL = normalizePath(outPath)
        try pngData.write(to: outURL, options: [.atomic])
        print("Wrote \(result.width)x\(result.height) PNG (\(result.byteCount) bytes) to \(outURL.path)")
        return 0
    }

    /// `workspaces automation workspace list [--json]` — the operator-scope read of the app's repos and
    /// workspaces (`workspace.read`). Like `window list`, it reads the per-launch operator credential
    /// file (minted next to the socket by an opted-in launch) rather than the injected terminal
    /// environment, so it works from any same-user shell outside a WorkSpaces tile. Absent the
    /// credential it fails closed with guidance. This is the app plane's source of truth; `ws list`
    /// derives from it too when the app is running, adding the CLI-local-only rows the app cannot see.
    private func runWorkspaceOperator(arguments: [String]) throws -> Int32 {
        switch arguments.first {
        case "list":
            return try runWorkspaceList(arguments: arguments)
        case "select":
            return try runWorkspaceSelect(arguments: Array(arguments.dropFirst()))
        case "create":
            return try runWorkspaceCreate(arguments: Array(arguments.dropFirst()))
        case "archive":
            return try runWorkspaceArchive(arguments: Array(arguments.dropFirst()))
        default:
            throw CLIError(
                "Usage: workspaces automation workspace list [--json] | workspace select <id> [--json] | workspace create <repo-id> <name> [--provider <id>] [--guest-os <linux|macos>] [--json] | workspace archive <id> [--json]"
            )
        }
    }

    private func runWorkspaceList(arguments: [String]) throws -> Int32 {
        let usage = "workspaces automation workspace list [--json]"
        var json = false
        for argument in arguments.dropFirst() {
            switch argument {
            case "--json":
                json = true
            default:
                throw CLIError("Usage: \(usage)")
            }
        }

        let credential = try loadOperatorCredential()
        let result = try operatorRequest(
            AutomationWorkspacesResult.self,
            credential: credential,
            method: "GET",
            path: "/v1/workspaces",
            body: Data()
        )

        if json {
            print(try AutomationCLIResultPrinter.resultJSON(result))
            return 0
        }

        if result.repos.isEmpty && result.workspaces.isEmpty {
            print("No repos or workspaces.")
            return 0
        }

        if !result.repos.isEmpty {
            print("Repos:")
            for repo in result.repos {
                let marker = repo.isSelected ? "*" : " "
                print("\(marker) \(repo.repoID)\t\(repo.name)\t\(repo.path)")
            }
        }
        if !result.workspaces.isEmpty {
            if !result.repos.isEmpty {
                print("")
            }
            print("Workspaces:")
            for workspace in result.workspaces {
                let marker = workspace.isSelected ? "*" : " "
                let branch = workspace.branch ?? "-"
                print(
                    "\(marker) \(workspace.workspaceID)\t\(workspace.name)\t"
                        + "\(workspace.status)\t\(workspace.backend)\t\(branch)"
                )
            }
        }
        return 0
    }

    /// `workspaces automation workspace create <repo-id> <name> [--provider <id>] [--guest-os <linux|macos>] [--json]`
    /// drives the running app's real sidebar create helper via the operator socket. A completed
    /// response means the app created the workspace, selected it, and attached its terminal; setup
    /// sheets return `confirmation_required` with the confirmation payload instead of blocking.
    private func runWorkspaceCreate(arguments: [String]) throws -> Int32 {
        let usage =
            "workspaces automation workspace create <repo-id> <name> [--provider <id>] [--guest-os <linux|macos>] [--json]"
        var json = false
        var repoID: String?
        var name: String?
        var providerID: String?
        var guestOS: WorkspaceGuestOS?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                json = true
                index += 1
            case "--provider":
                guard index + 1 < arguments.count else { throw CLIError("Usage: \(usage)") }
                providerID = arguments[index + 1]
                index += 2
            case "--guest-os":
                guard index + 1 < arguments.count else { throw CLIError("Usage: \(usage)") }
                guard let parsed = WorkspaceGuestOS(rawValue: arguments[index + 1]) else {
                    throw CLIError("Unsupported guest OS '\(arguments[index + 1])'. Use linux or macos.")
                }
                guestOS = parsed
                index += 2
            default:
                if repoID == nil {
                    repoID = argument
                } else if name == nil {
                    name = argument
                } else {
                    throw CLIError("Usage: \(usage)")
                }
                index += 1
            }
        }

        guard let repoID, !repoID.isEmpty, let name, !name.isEmpty else {
            throw CLIError("Usage: \(usage)")
        }

        let credential = try loadOperatorCredential()
        let request = AutomationWorkspaceCreateRequest(
            repoID: repoID,
            name: name,
            providerID: providerID,
            guestOS: guestOS
        )
        let body = try JSONEncoder().encode(request)
        let result = try operatorRequest(
            AutomationWorkspaceCreateResult.self,
            credential: credential,
            method: "POST",
            path: "/v1/workspace/create",
            body: body
        )

        if json {
            print(try AutomationCLIResultPrinter.resultJSON(result))
            return 0
        }

        switch result.outcome {
        case .completed:
            let id = result.workspaceID?.uuidString ?? "-"
            if result.attachedTerminal {
                let surface = result.attachedSurfaceID ?? "-"
                print("Created \(result.workspaceName) (\(id)) — terminal attached (surface \(surface)).")
            } else {
                print("Created \(result.workspaceName) (\(id)) — no terminal attached.")
            }
        case .confirmationRequired:
            print("Confirmation required: \(result.message ?? "the app needs confirmation to proceed.")")
        }
        return 0
    }

    /// `workspaces automation workspace select <id> [--json]` — an operator mutation verb. Drives the
    /// running app's real selection gesture (the same path a sidebar click takes) via the socket, so
    /// the app highlights the workspace, attaches its terminal, and requests focus. `<id>` is a stable
    /// workspace id from `workspace list`. Operator scope: reads the per-launch credential, so it works
    /// from any same-user shell outside a tile.
    private func runWorkspaceSelect(arguments: [String]) throws -> Int32 {
        let usage = "workspaces automation workspace select <id> [--json]"
        var json = false
        var workspaceID: String?
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            default:
                guard workspaceID == nil else { throw CLIError("Usage: \(usage)") }
                workspaceID = argument
            }
        }
        guard let workspaceID, !workspaceID.isEmpty else {
            throw CLIError("Usage: \(usage)")
        }

        let credential = try loadOperatorCredential()
        let body = try JSONSerialization.data(withJSONObject: ["workspaceID": workspaceID])
        let result = try operatorRequest(
            AutomationWorkspaceSelectResult.self,
            credential: credential,
            method: "POST",
            path: "/v1/workspace/select",
            body: body
        )

        if json {
            print(try AutomationCLIResultPrinter.resultJSON(result))
            return 0
        }

        switch result.outcome {
        case .completed:
            if result.attachedTerminal {
                let surface = result.attachedSurfaceID ?? "-"
                print("Selected \(result.workspaceID) — terminal attached (surface \(surface)).")
            } else {
                print("Selected \(result.workspaceID) — no terminal attached.")
            }
        case .confirmationRequired:
            print("Confirmation required: \(result.message ?? "the app needs confirmation to proceed.")")
        }
        return 0
    }

    /// `workspaces automation workspace archive <id> [--json]` — an operator mutation verb. Drives the
    /// running app's real sidebar archive gesture, so the row leaves the active list exactly as it
    /// would from the sidebar menu. `<id>` is a stable workspace id from `workspace list`.
    private func runWorkspaceArchive(arguments: [String]) throws -> Int32 {
        let usage = "workspaces automation workspace archive <id> [--json]"
        var json = false
        var workspaceID: String?
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            default:
                guard workspaceID == nil else { throw CLIError("Usage: \(usage)") }
                workspaceID = argument
            }
        }
        guard let workspaceID, !workspaceID.isEmpty else {
            throw CLIError("Usage: \(usage)")
        }

        let credential = try loadOperatorCredential()
        let body = try JSONSerialization.data(withJSONObject: ["workspaceID": workspaceID])
        let result = try operatorRequest(
            AutomationWorkspaceArchiveResult.self,
            credential: credential,
            method: "POST",
            path: "/v1/workspace/archive",
            body: body
        )

        if json {
            print(try AutomationCLIResultPrinter.resultJSON(result))
            return 0
        }

        switch result.outcome {
        case .completed:
            let selected = result.selectedWorkspaceID?.uuidString ?? "-"
            print("Archived \(result.workspaceID) — selected workspace \(selected).")
        case .confirmationRequired:
            print("Confirmation required: \(result.message ?? "the app needs confirmation to proceed.")")
        }
        return 0
    }

    private func operatorRequest<Result>(
        _ type: Result.Type = Result.self,
        credential: AutomationOperatorCredential,
        method: String,
        path: String,
        body: Data
    ) throws -> Result where Result: Codable & Sendable & Equatable {
        let client = AutomationSocketClient(socketPath: credential.socketPath)
        let response = try client.request(
            method: method,
            path: path,
            handle: credential.handle,
            body: body
        )
        do {
            return try AutomationCLIResultPrinter.decodeEnvelope(type, from: response)
        } catch let error as AutomationServiceError {
            throw CLIError(
                "automation request failed: \(error.response.code.rawValue): \(error.response.message)"
            )
        }
    }

    private func loadOperatorCredential() throws -> AutomationOperatorCredential {
        let url = AutomationOperatorCredentialStore.defaultURL(bundleIdentifier: Self.appBundleIdentifier)
        guard let credential = AutomationOperatorCredentialStore.load(from: url) else {
            throw CLIError(
                "Operator credential not found at \(url.path). Launch WorkSpaces with the Automation "
                    + "Operator experiment enabled (or WORKSPACES_AUTOMATION_OPERATOR=1) and try again."
            )
        }
        return credential
    }

    private func performAutomationRequest<Result>(
        _ type: Result.Type = Result.self,
        method: String,
        path: String,
        requiresHandle: Bool,
        body: Data = Data()
    ) throws -> Result where Result: Codable & Sendable & Equatable {
        let client = try automationClient()
        let handle = try automationHandle(required: requiresHandle)
        let response = try client.request(
            method: method,
            path: path,
            handle: handle,
            body: body
        )
        do {
            return try AutomationCLIResultPrinter.decodeEnvelope(type, from: response)
        } catch let error as AutomationServiceError {
            throw CLIError(
                "automation request failed: \(error.response.code.rawValue): \(error.response.message)"
            )
        }
    }

    private func performAutomationHealthRequest() throws -> AutomationHealthResult {
        let response = try automationClient().request(
            method: "GET",
            path: "/v1/health",
            handle: nil,
            body: Data()
        )
        do {
            return try AutomationCLIResultPrinter.decodeHealthEnvelope(
                from: response,
                bundledCLIPath: Self.bundledCLIPath()
            )
        } catch let error as AutomationCLIResponseError {
            throw CLIError(error.localizedDescription)
        } catch let error as AutomationServiceError {
            throw CLIError(
                "automation request failed: \(error.response.code.rawValue): \(error.response.message)"
            )
        }
    }

    private static func healthLine(_ result: AutomationHealthResult) -> String {
        guard let server = result.server else {
            return result.status.uppercased()
        }
        let experiments = server.experiments.isEmpty ? "-" : server.experiments.joined(separator: ",")
        return "\(result.status.uppercased()) pid=\(server.pid) launchedAt=\(server.launchedAt) "
            + "protocol=\(server.protocolVersion) experiments=\(experiments)"
    }

    private static func bundledCLIPath() -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier) {
            return appURL.appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("workspaces", isDirectory: false).path
        }
        return Bundle.main.executablePath ?? "workspaces"
    }

    private func automationClient() throws -> AutomationSocketClient {
        let environment = ProcessInfo.processInfo.environment
        let socketPath =
            environment[AutomationAPI.socketEnvironmentKey]
            ?? AutomationListener.defaultSocketURL(bundleIdentifier: Self.appBundleIdentifier).path
        return AutomationSocketClient(socketPath: socketPath)
    }

    private func automationHandle(required: Bool) throws -> String? {
        guard required else { return nil }
        guard
            let handle = ProcessInfo.processInfo.environment[AutomationAPI.handleEnvironmentKey],
            !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CLIError(
                "\(AutomationAPI.handleEnvironmentKey) is missing. Run this command from a WorkSpaces terminal tile."
            )
        }
        return handle
    }

    private func requireJSONFlag(arguments: [String], usage: String) throws -> Bool {
        guard arguments == ["--json"] else {
            throw CLIError("Usage: \(usage)")
        }
        return true
    }

    private func singleDirectionFlag<Direction>(
        _ type: Direction.Type,
        arguments: [String],
        usage: String
    ) throws -> Direction where Direction: CaseIterable & RawRepresentable, Direction.RawValue == String {
        guard arguments.count == 1, let rawFlag = arguments.first, rawFlag.hasPrefix("--") else {
            throw CLIError("Usage: \(usage)")
        }
        let rawValue = String(rawFlag.dropFirst(2))
        guard let direction = Direction(rawValue: rawValue) else {
            throw CLIError("Usage: \(usage)")
        }
        return direction
    }

    private func directionBody(_ direction: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["direction": direction], options: [.sortedKeys])
    }

    private func printGitStatus(for workspace: WorkspaceRecord, workspaceURL: URL) async throws {
        print("Workspace: \(workspaceDisplayName(workspace))")
        let changes = try await gitService.getStatus(at: workspaceURL)
        if changes.isEmpty {
            print("clean")
            return
        }

        for change in changes.sorted(by: { $0.path < $1.path }) {
            print("\(change.status.rawValue)\t\(change.path)")
        }
    }

    private func markWorkspaceAccess(workspaceID: UUID, command: String?, state: inout CLIState) {
        let now = Date()

        if let index = state.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            state.workspaces[index].lastAccessedAt = now
        }

        state.recents.removeAll { $0.workspaceID == workspaceID }
        state.recents.insert(
            RecentSession(workspaceID: workspaceID, command: command, openedAt: now),
            at: 0
        )
        if state.recents.count > 20 {
            state.recents = Array(state.recents.prefix(20))
        }

        state.lastSession = LastSession(workspaceID: workspaceID, command: command, openedAt: now)
    }

    private func updateWorkspace(_ workspace: WorkspaceRecord, state: inout CLIState) {
        guard let index = state.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            return
        }
        state.workspaces[index] = workspace
    }

    private func resolveRepo(token: String, state: CLIState) -> RepoRecord? {
        if let byName = state.repos.first(where: { $0.name == token }) {
            return byName
        }

        let normalizedTokenPath = normalizePath(token).path
        return state.repos.first(where: { $0.path == normalizedTokenPath })
    }

    /// Resolves a repo token against the CLI-local store; when it misses and the running
    /// app tracks the repo instead, the error explains the plane split and both ways out.
    private func resolveLocalRepoOrExplain(token: String, state: CLIState) throws -> RepoRecord {
        if let repo = resolveRepo(token: token, state: state) {
            return repo
        }
        if let inventory = appInventory(),
            let guidance = CLIPlaneComposer.missingLocalRepoGuidance(
                token: token,
                normalizedTokenPath: normalizePath(token).path,
                app: inventory
            )
        {
            throw CLIError(guidance)
        }
        if appRunningWithoutOperatorCredential() {
            writeStderr(CLIPlaneComposer.operatorCredentialMissingHint)
        }
        throw CLIError("Repository not found: \(token)")
    }

    /// Resolves a workspace selector against the CLI-local store first, then against the
    /// running app's inventory. An app-side match is adopted into local state (keyed by
    /// path) so flows that persist access records (`open`, `run`) keep working; callers
    /// that never save (`ws path`, `status`) leave the adoption in memory only.
    private func resolveWorkspace(token: String, state: inout CLIState) throws -> WorkspaceRecord {
        if let uuid = UUID(uuidString: token),
            let byID = state.workspaces.first(where: { $0.id == uuid })
        {
            return byID
        }

        if token.contains("/") {
            let parts = token.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2,
                let exact = state.workspaces.first(where: { $0.repoName == parts[0] && $0.name == parts[1] })
            {
                return exact
            }
        }

        let matches = state.workspaces.filter { $0.name == token }
        if matches.count == 1, let workspace = matches.first {
            return workspace
        }
        if matches.count > 1 {
            let candidates = matches.map(workspaceDisplayName).joined(separator: ", ")
            throw CLIError("Workspace name is ambiguous: \(token). Candidates: \(candidates)")
        }

        if let inventory = appInventory() {
            switch CLIPlaneComposer.matchWorkspace(token: token, in: inventory) {
            case .match(let match):
                let now = Date()
                // A local record at the same path is superseded by the app-derived one, but
                // the fields the app never knew about are the local plane's own: keep the
                // user's default command and the original creation time.
                let superseded = state.workspaces.first { $0.path == match.path }
                let record = WorkspaceRecord(
                    id: match.workspaceID,
                    name: match.name,
                    repoName: match.repoName ?? "",
                    repoPath: match.repoPath ?? "",
                    path: match.path,
                    gitBranch: match.branch ?? "",
                    createdAt: superseded?.createdAt ?? now,
                    lastAccessedAt: now,
                    defaultCommand: superseded?.defaultCommand
                )
                state.workspaces.removeAll { $0.path == record.path }
                state.workspaces.append(record)
                return record
            case .ambiguous(let candidates):
                throw CLIError(
                    "Workspace name is ambiguous in the running app: \(token). "
                        + "Candidates: \(candidates.joined(separator: ", "))"
                )
            case .none:
                break
            }
        }

        throw CLIError("Workspace not found: \(token)")
    }

    /// Default ceiling for the inventory probe, in seconds. Inert until `AutomationSocketClient`
    /// gains a read timeout (open PR #1241) — see `appInventory(withDeadline:)`.
    private static let appInventoryProbeDeadline: TimeInterval = 2

    /// The running app's repo/workspace inventory via the operator socket, or nil when the
    /// appless plane is in effect (no operator credential, no listener, or a failed read).
    ///
    /// Every local verb that consults the app plane funnels through this one seam, so the
    /// blocking-probe bound has exactly one place to land. `deadline` is accepted and
    /// documented now but **inert**: `AutomationSocketClient` has no timeout parameter until
    /// open PR #1241 lands one, and this PR does not touch that file. Once #1241 merges, the
    /// wiring is a single line here (pass `deadline` into the client) and no call site moves.
    private func appInventory(
        withDeadline deadline: TimeInterval = CLIApp.appInventoryProbeDeadline
    ) -> AutomationWorkspaceInventory? {
        // Held, not applied: the socket client takes no timeout parameter yet (#1241).
        _ = deadline
        guard let credential = try? loadOperatorCredential() else {
            return nil
        }
        guard
            let result = try? operatorRequest(
                AutomationWorkspacesResult.self,
                credential: credential,
                method: "GET",
                path: "/v1/workspaces",
                body: Data()
            )
        else {
            return nil
        }
        return AutomationWorkspaceInventory(repos: result.repos, workspaces: result.workspaces)
    }

    /// True when the app is running but no operator credential is readable — `appInventory`
    /// returns nil, every cross-plane hint stays silent, and a repo the app tracks reads as
    /// simply missing. That is the 2026-08-07 probe scenario, so the miss paths say so.
    private func appRunningWithoutOperatorCredential() -> Bool {
        guard (try? loadOperatorCredential()) == nil else {
            return false
        }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleIdentifier).isEmpty
    }

    private func runInteractiveSession(in directory: URL, command: String?) throws -> Int32 {
        let process = Process()
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        if let command {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["--login"]
        }

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func runCapturedCommand(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        group.enter()

        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }

        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrHandle.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        return ProcessExecutionResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - State

private struct CLIStateStore {
    func load() throws -> CLIState {
        let stateURL = CLIPaths.stateFile
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return CLIState()
        }

        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(CLIState.self, from: data)
    }

    func save(_ state: CLIState) throws {
        try FileManager.default.createDirectory(
            at: CLIPaths.configDirectory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: CLIPaths.stateFile, options: [.atomic])
    }
}

private enum CLIPaths {
    static var configDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("workspaces-cli")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("workspaces-cli")
    }

    static var stateFile: URL {
        configDirectory.appendingPathComponent("state.json")
    }
}

private struct CLIState: Codable {
    var version = 1
    var repos: [RepoRecord] = []
    var workspaces: [WorkspaceRecord] = []
    var recents: [RecentSession] = []
    var lastSession: LastSession?
    // Optional so state.json files written before race groups existed keep decoding.
    var raceGroups: [RaceGroupRecord]?
}

private struct RepoRecord: Codable {
    var id: UUID
    var name: String
    var path: String
    var addedAt: Date
}

private struct WorkspaceRecord: Codable {
    var id: UUID
    var name: String
    var repoName: String
    var repoPath: String
    var path: String
    var gitBranch: String
    var createdAt: Date
    var lastAccessedAt: Date
    var defaultCommand: String?
}

private struct RaceGroupRecord: Codable {
    var id: UUID
    var slug: String
    var repoName: String
    var prompt: String
    var command: String
    var workspaceIDs: [UUID]
    var createdAt: Date
    var agentPIDs: [Int32]
}

private struct RecentSession: Codable {
    var workspaceID: UUID
    var command: String?
    var openedAt: Date
}

private struct LastSession: Codable {
    var workspaceID: UUID
    var command: String?
    var openedAt: Date
}

private struct ProcessExecutionResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

private struct WorkspaceLocalConfig {
    var defaultCommand: String?
    var setupHook: String?
    var archiveHook: String?
}

private struct AppLaunchRequest {
    let launchDirectory: URL
    let repoRoot: URL?

    init(launchDirectory: URL) throws {
        var isDirectory = ObjCBool(false)
        guard
            FileManager.default.fileExists(atPath: launchDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CLIError("Path is not a directory: \(launchDirectory.path)")
        }

        let normalizedDirectory = launchDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.launchDirectory = normalizedDirectory
        repoRoot = resolveGitTopLevel(for: normalizedDirectory)
    }

    var deepLinkURL: URL {
        WorkspacesFocusLink(
            cwd: launchDirectory.path,
            repoRoot: repoRoot?.path,
            source: "cli"
        )
        .url
    }
}

// MARK: - Helpers

private struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The CLI's path spelling and the one `CLIPlaneComposer` compares against the app's
/// descriptors are the same pipeline, so a trailing slash or a symlinked spelling of the
/// same directory never reads as two different places across the planes.
private func normalizePath(_ path: String) -> URL {
    CLIPathNormalizer.normalizedURL(path)
}

private func validateGitRepository(at url: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CLIError("Not a directory: \(url.path)")
    }

    let gitDir = url.appendingPathComponent(".git").path
    guard FileManager.default.fileExists(atPath: gitDir) else {
        throw CLIError("Not a git repository: \(url.path)")
    }
}

private func resolveGitTopLevel(for directory: URL) -> URL? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path, "rev-parse", "--show-toplevel"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return nil
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    guard
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !output.isEmpty
    else {
        return nil
    }

    return URL(fileURLWithPath: output, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

private func openApplication(at appURL: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                continuation.resume(throwing: CLIError("Failed to launch WorkSpaces: \(error.localizedDescription)"))
                return
            }

            continuation.resume()
        }
    }
}

private func resolveExecutable(_ name: String) throws -> String {
    if name.contains("/") {
        let absolute = normalizePath(name).path
        guard FileManager.default.isExecutableFile(atPath: absolute) else {
            throw CLIError("Command not executable: \(absolute)")
        }
        return absolute
    }

    let pathValue =
        ProcessInfo.processInfo.environment["PATH"]
        ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in pathValue.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    throw CLIError("Command not found: \(name)")
}

private func workspaceDisplayName(_ workspace: WorkspaceRecord) -> String {
    "\(workspace.repoName)/\(workspace.name)"
}

private func loadWorkspaceLocalConfig(at directory: URL) -> WorkspaceLocalConfig {
    let configURL = directory.appendingPathComponent(".workspaces.toml")
    guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
        return WorkspaceLocalConfig()
    }

    var config = WorkspaceLocalConfig()
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") {
            continue
        }
        guard let separator = line.firstIndex(of: "=") else { continue }

        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parseTomlString(line[line.index(after: separator)...])

        switch key {
        case "default_command":
            config.defaultCommand = value
        case "setup_hook":
            config.setupHook = value
        case "archive_hook":
            config.archiveHook = value
        default:
            continue
        }
    }

    return config
}

private func parseTomlString<S: StringProtocol>(_ rawValue: S) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
        let inner = trimmed.dropFirst().dropLast()
        return
            inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
    }
    if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
        return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
}

private func writeStderr(_ message: String) {
    var final = message
    if !final.hasSuffix("\n") {
        final += "\n"
    }
    if let data = final.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func printHelp() {
    print(CLIVerbCatalog.helpText)
}
