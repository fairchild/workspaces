//
//  GhosttyTerminalConfig.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "GhosttyTerminalConfig")

struct GhosttyTerminalConfig {
    private enum ShellProfileMode: String {
        case login
        case clean

        static func resolve(from environment: [String: String]) -> Self {
            let rawValue = environment["WORKSPACES_SHELL_PROFILE_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch rawValue {
            case "clean":
                return .clean
            default:
                return .login
            }
        }
    }

    let fontSize: Float32
    let workingDirectory: String
    let command: String?
    let environmentVariables: [String: String]
    let shellProfileModeLabel: String

    /// The bare `exec tmux new-session -A …` script this surface's shell should run,
    /// or `nil` when the surface is not tmux-backed. `command` wraps the same script
    /// in a login shell for libghostty; this is the unwrapped form, safe to type into
    /// an already-running shell when the wrapped one never arrived (#1478, #889).
    let tmuxLaunchScript: String?

    init(
        launchContext: TerminalSessionLaunchContext,
        fontSize: Float32 = 13,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        terminalMultiplexingMode: TerminalMultiplexingMode? = nil,
        isTmuxAvailableOverride: Bool? = nil
    ) {
        switch launchContext.commandMode {
        case .customCommand(let customCommand):
            self.init(customCommand: customCommand, fontSize: fontSize)

        case .directoryShell:
            self.init(
                workingDirectory: launchContext.workingDirectory,
                fontSize: fontSize,
                environment: environment,
                terminalMultiplexingMode: terminalMultiplexingMode,
                isTmuxAvailableOverride: isTmuxAvailableOverride,
                hostSessionID: launchContext.hostSessionID,
                hooksSocketPath: launchContext.hooksSocketPath,
                automationEnvironment: launchContext.automationEnvironment,
                tmuxSessionName: launchContext.tmuxSessionName
            )
        }
    }

    init(
        workingDirectory: URL,
        fontSize: Float32 = 13,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        terminalMultiplexingMode: TerminalMultiplexingMode? = nil,
        isTmuxAvailableOverride: Bool? = nil,
        tmuxSupportsSessionEnvironmentFlagOverride: Bool? = nil,
        hostSessionID: UUID? = nil,
        hooksSocketPath: String? = nil,
        automationEnvironment: AutomationTerminalEnvironment? = nil,
        tmuxSessionName: String? = nil
    ) {
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory.path

        var environment = environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"

        // Command hook plumbing: when both pieces of context are available,
        // expose them to the embedded shell so Agent hooks can address the host's
        // hook listener over its Unix socket without per-process discovery.
        if let hooksSocketPath, let hostSessionID {
            environment["WORKSPACES_HOOKS_SOCKET"] = hooksSocketPath
            environment["WORKSPACES_HOST_SESSION_ID"] = hostSessionID.uuidString
            if let commandStatusHookPath = ClaudeIntegrationLifecycle.bundledCommandStatusHookPath() {
                environment["WORKSPACES_COMMAND_STATUS_ZSH"] = commandStatusHookPath
            }
        }
        if let automationEnvironment {
            environment[AutomationAPI.socketEnvironmentKey] = automationEnvironment.socketPath
            environment[AutomationAPI.handleEnvironmentKey] = automationEnvironment.handle
        }

        // Shared with TmuxSessionProbe.defaultEnvironment, so a session the probe
        // reports alive is one this launch gate can also see tmux for.
        environment["PATH"] = TmuxSessionProbe.pathPrependingToolPaths(environment["PATH"])

        let shell = environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        let shellProfileMode = ShellProfileMode.resolve(from: environment)
        if shellProfileMode == .clean, environment["WORKSPACES_TERMINAL_DIAGNOSTICS"] == "1" {
            Self.installDiagnosticPromptMarker(for: shellName, environment: &environment)
        }
        let mode = terminalMultiplexingMode ?? TerminalMultiplexingMode.resolve()
        let tmuxAvailable =
            isTmuxAvailableOverride
            ?? Self.isExecutableAvailable(
                "tmux",
                inPath: environment["PATH"]
            )

        if mode == .tmuxPerSession, tmuxAvailable {
            // The chosen name (split-pane disambiguation, restore's probed reattach
            // target) wins over the directory derivation, so what launches is what
            // the continuity row recorded.
            let tmuxSessionName = tmuxSessionName ?? Self.tmuxSessionName(for: workingDirectory)
            let tmuxScript = Self.tmuxLaunchScript(
                sessionName: tmuxSessionName,
                workingDirectory: workingDirectory,
                sessionEnvironment: Self.tileScopedEnvironment(from: environment),
                seedsEnvironmentOnCreate: tmuxSupportsSessionEnvironmentFlagOverride
                    ?? Self.tmuxSupportsSessionEnvironmentFlag
            )
            self.command = Self.shellInvocation(shell: shell, profileMode: shellProfileMode, command: tmuxScript)
            self.tmuxLaunchScript = tmuxScript
        } else {
            self.command = Self.shellInvocation(shell: shell, profileMode: shellProfileMode)
            self.tmuxLaunchScript = nil
        }
        self.shellProfileModeLabel = shellProfileMode.rawValue
        self.environmentVariables = environment
    }

    /// Create a config with a custom command (e.g. SSH to a remote sandbox).
    /// The working directory is a local placeholder — the command itself determines the remote context.
    init(customCommand: String, fontSize: Float32 = 13) {
        self.fontSize = fontSize
        self.workingDirectory = FileManager.default.temporaryDirectory.path
        self.command = customCommand
        self.tmuxLaunchScript = nil
        self.shellProfileModeLabel = "custom"
        self.environmentVariables = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
    }

    private static func shellInvocation(
        shell: String,
        profileMode: ShellProfileMode,
        command: String? = nil
    ) -> String {
        let shellName = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        let arguments: [String]

        switch (shellName, profileMode) {
        case ("zsh", .login):
            arguments = ["--login"]
        case ("zsh", .clean):
            arguments = ["-f"]
        case ("bash", .login):
            arguments = ["--login"]
        case ("bash", .clean):
            arguments = ["--noprofile", "--norc"]
        default:
            arguments = profileMode == .login ? ["--login"] : []
        }

        var components = [shell]
        components.append(contentsOf: arguments)
        if let command {
            components.append("-c")
            components.append(Self.singleQuoted(command))
        }
        return components.joined(separator: " ")
    }

    private static func installDiagnosticPromptMarker(
        for shellName: String,
        environment: inout [String: String]
    ) {
        let titleMarker = "\u{1B}]0;WorkSpaces Ready\u{7}"
        switch shellName {
        case "zsh":
            environment["PROMPT"] = "%{\(titleMarker)%}%# "
        case "bash":
            environment["PS1"] = "\\[\(titleMarker)\\]\\$ "
        default:
            break
        }
    }

    private static func isExecutableAvailable(_ executable: String, inPath path: String?) -> Bool {
        guard let path else { return false }
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return true
            }
        }
        return false
    }

    static func tmuxSessionName(for directory: URL) -> String {
        TmuxSessionNaming.defaultName(for: directory)
    }

    /// Environment keys whose values belong to *this tile and this launch*: the
    /// automation handle a CLI verb resolves its caller tile from, its socket,
    /// and the hook context that attributes command status to a host session.
    ///
    /// One tmux server backs every session on the `-L workspaces` socket, and a
    /// pane's shell inherits the *server's* environment — the environment of
    /// whichever tile happened to start it. These keys therefore travel in the
    /// tmux session's own environment instead, so every pane sees its own tile.
    /// Ordered, so a launch command is deterministic.
    static let tileScopedEnvironmentKeys: [String] = [
        AutomationAPI.socketEnvironmentKey,
        AutomationAPI.handleEnvironmentKey,
        "WORKSPACES_HOOKS_SOCKET",
        "WORKSPACES_HOST_SESSION_ID",
        "WORKSPACES_COMMAND_STATUS_ZSH",
    ]

    static func tileScopedEnvironment(from environment: [String: String]) -> [(key: String, value: String)] {
        tileScopedEnvironmentKeys.compactMap { key in
            environment[key].map { (key: key, value: $0) }
        }
    }

    /// Whether the tmux this app will launch understands `new-session -e`, resolved
    /// once per process: a surface composes its launch command synchronously, so the
    /// question cannot be awaited per launch, and the answer cannot change under a
    /// running app without a tmux upgrade mid-session.
    ///
    /// Fires a one-time notice on the fallback path, because that path is invisible
    /// in the launch command a user would think to look at and explains a first pane
    /// that came up holding the wrong tile's handle.
    private static let tmuxSupportsSessionEnvironmentFlag: Bool = {
        let probe = TmuxSessionProbe()
        let version = probe.version()
        let supported = TmuxSessionProbe.supportsSessionEnvironmentFlag(version: version)
        if !supported {
            let described = version.map { "\($0.major).\($0.minor)" } ?? "unreadable"
            let minimum = TmuxSessionProbe.sessionEnvironmentFlagVersion
            let required = "\(minimum.major).\(minimum.minor)"
            log.notice(
                """
                tmux version \(described, privacy: .public) predates \(required, privacy: .public): \
                no new-session -e, so each tile's environment is set after its session is created \
                and a newly created session's first pane inherits the tmux server's environment
                """
            )
        }
        return supported
    }()

    /// The `-c` script a tmux-mode surface's shell execs: attach-or-create this
    /// tile's session with its own tile-scoped environment.
    ///
    /// `new-session -e` seeds that environment when the session is created. When
    /// `-A` instead attaches a session that survived an earlier launch, tmux
    /// ignores `-e` and the session still carries the recorded launch's values,
    /// so the chained `set-environment` — one tmux command sequence, run after
    /// create-or-attach on either path — is what makes the live session name
    /// this launch. Chaining rather than probing first is deliberate: a
    /// `has-session` probe leaves a window in which another launch creates the
    /// session, and the attach that follows would silently keep that launch's
    /// handle.
    ///
    /// `seedsEnvironmentOnCreate` is false for a tmux older than
    /// `TmuxSessionProbe.sessionEnvironmentFlagVersion`, which rejects `-e` and
    /// would fail the launch outright. The chained `set-environment` still runs
    /// there, so everything except a freshly created session's *first* pane gets
    /// its own tile — the reattach and later-pane paths are unaffected.
    ///
    /// Panes spawned after this point inherit the session environment. A shell
    /// already running in a surviving pane keeps the environment it was spawned
    /// with; tmux cannot rewrite a live process.
    static func tmuxLaunchScript(
        sessionName: String,
        workingDirectory: URL,
        sessionEnvironment: [(key: String, value: String)],
        seedsEnvironmentOnCreate: Bool = true
    ) -> String {
        let tmux = "tmux -L \(TmuxSessionProbe.socketLabel)"
        // `=` forces an exact name match, as in TmuxSessionProbe.isSessionAlive.
        let exactTarget = singleQuoted("=\(sessionName)")

        var script =
            "exec \(tmux) new-session -A -s \(singleQuoted(sessionName)) -c \(singleQuoted(workingDirectory.path))"
        // On the create path the first pane's shell spawns as part of `new-session`,
        // before the chained commands run, so `-e` — not the `set-environment`
        // below — is what that pane inherits. These pairs stay on `new-session`.
        if seedsEnvironmentOnCreate {
            for pair in sessionEnvironment {
                script += " -e \(singleQuoted("\(pair.key)=\(pair.value)"))"
            }
        }
        for pair in sessionEnvironment {
            // `\;` reaches tmux as a bare `;` argument: its command separator.
            script += " \\; set-environment -t \(exactTarget) \(singleQuoted(pair.key)) \(singleQuoted(pair.value))"
        }
        return script
    }

    /// `tmuxLaunchScript` made safe to type into a shell whose state is not fully
    /// known. The `$TMUX` test short-circuits the whole chain when the shell already
    /// sits inside tmux, so a repair racing a launch that just attached does nothing
    /// instead of `exec`-ing a nested tmux — which tmux refuses, taking the exec'd
    /// shell (and the pane) down with it.
    static func tmuxRepairScript(_ launchScript: String) -> String {
        "[ -z \"$TMUX\" ] && \(launchScript)"
    }

    private static func singleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    func withCValue<T>(view: NSView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))

        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        config.scale_factor = scale
        config.font_size = fontSize
        config.wait_after_command = false
        // Embedded terminals should behave like panes, not standalone windows.
        // This prevents shell exit from propagating window-close semantics.
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        return try workingDirectory.withCString { workingDirectoryPtr in
            config.working_directory = workingDirectoryPtr

            return try command.withCString { commandPtr in
                config.command = commandPtr

                let environmentPairs = environmentVariables.map { ($0.key, $0.value) }
                let keys = environmentPairs.map { $0.0 }
                let values = environmentPairs.map { $0.1 }

                return try keys.withCStrings { keyPointers in
                    return try values.withCStrings { valuePointers in
                        var envVars = [ghostty_env_var_s]()
                        envVars.reserveCapacity(min(keyPointers.count, valuePointers.count))

                        let count = min(keyPointers.count, valuePointers.count)
                        for index in 0..<count {
                            envVars.append(
                                ghostty_env_var_s(
                                    key: keyPointers[index],
                                    value: valuePointers[index]
                                ))
                        }

                        return try envVars.withUnsafeMutableBufferPointer { buffer in
                            config.env_vars = buffer.baseAddress
                            config.env_var_count = buffer.count
                            return try body(&config)
                        }
                    }
                }
            }
        }
    }
}

extension Optional where Wrapped == String {
    fileprivate func withCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if let value = self {
            return try value.withCString(body)
        }
        return try body(nil)
    }
}

extension Array where Element == String {
    fileprivate func withCStrings<T>(_ body: ([UnsafePointer<CChar>?]) throws -> T) rethrows -> T {
        if isEmpty {
            return try body([])
        }

        func recurse(index: Int, pointers: [UnsafePointer<CChar>?]) throws -> T {
            if index == count {
                return try body(pointers)
            }

            return try self[index].withCString { pointer in
                var nextPointers = pointers
                nextPointers.append(pointer)
                return try recurse(index: index + 1, pointers: nextPointers)
            }
        }

        return try recurse(index: 0, pointers: [])
    }
}
