//
//  GhosttyTerminalConfigTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("GhosttyTerminalConfig")
struct GhosttyTerminalConfigTests {
    @Test("Ghostty mode uses plain login shell command")
    func ghosttyModeUsesLoginShell() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        #expect(config.command == "/bin/zsh --login")
        #expect(config.tmuxLaunchScript == nil)
    }

    @Test("tmux mode exposes the bare attach script for launch-contract repair")
    func tmuxModeExposesBareLaunchScript() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_HOST_SESSION_ID": "host-session-1",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            tmuxSupportsSessionEnvironmentFlagOverride: true
        )

        // The repair types this into an already-running shell, so it must be the
        // unwrapped script — `exec tmux …`, not a nested login shell — and it must
        // still carry the tile-scoped environment the dropped config would have set.
        // The `-e` form is pinned by the override: whether this tmux understands the
        // flag is a property of the host, and CI's tmux is older than the laptop's.
        let script = try #require(config.tmuxLaunchScript)
        #expect(script.hasPrefix("exec tmux -L workspaces new-session -A -s "))
        #expect(!script.contains("/bin/zsh"))
        #expect(script.contains("WORKSPACES_HOST_SESSION_ID=host-session-1"))

        // `command` is the same script wrapped for libghostty, so it quotes the
        // script rather than containing it verbatim. Both must name one session.
        let sessionName = GhosttyTerminalConfig.tmuxSessionName(for: URL(fileURLWithPath: "/tmp/repo-a"))
        #expect(script.contains(sessionName))
        #expect(try #require(config.command).contains(sessionName))
    }

    @Test("The repair carries tile environment on a tmux too old for new-session -e")
    func repairCarriesEnvironmentWithoutSessionEnvironmentFlag() throws {
        // Older tmux rejects `-e`, so the tile-scoped pairs travel only on the chained
        // `set-environment`. The repair has to restore identity on that host too —
        // this is the shape CI runs.
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_HOST_SESSION_ID": "host-session-1",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            tmuxSupportsSessionEnvironmentFlagOverride: false
        )

        let script = try #require(config.tmuxLaunchScript)
        #expect(!script.contains("WORKSPACES_HOST_SESSION_ID=host-session-1"))
        #expect(script.contains("set-environment"))
        #expect(script.contains("'WORKSPACES_HOST_SESSION_ID' 'host-session-1'"))
    }

    @Test("The repair script refuses to run inside tmux")
    func repairScriptShortCircuitsInsideTmux() {
        // Typed into a shell that is already a tmux client — a repair racing a launch
        // that just attached — a bare `exec tmux` would nest, be refused, and take the
        // exec'd shell and its pane down. The guard makes that case a no-op.
        let repair = GhosttyTerminalConfig.tmuxRepairScript("exec tmux -L workspaces new-session -A -s 'x'")
        #expect(repair == "[ -z \"$TMUX\" ] && exec tmux -L workspaces new-session -A -s 'x'")
    }

    @Test("tmux mode without tmux available exposes no launch script")
    func tmuxUnavailableExposesNoLaunchScript() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: false
        )

        // A nil script is what tells the repair path to stay out: with no tmux on
        // PATH, a zero-client reading says nothing about whether the launch landed.
        #expect(config.tmuxLaunchScript == nil)
    }

    @Test("tmux mode launches deterministic session attach-or-create command")
    func tmuxModeLaunchesAttachOrCreateCommand() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let command = try #require(config.command)
        #expect(command.contains("/bin/zsh --login -c "))
        #expect(command.contains("tmux -L workspaces new-session -A -s"))
        #expect(command.contains("/tmp/repo-a"))
        #expect(command.contains("'wm-repo-a-"))
    }

    @Test("A resume session's launch command is identical to a plain shell's")
    func resumeSessionLaunchCommandMatchesPlainShell() throws {
        // The initial command is delivered by SurfaceStore over the automation
        // text bridge, never embedded in the launch command — libghostty ignores
        // a per-surface `command` for surfaces created after the app's first,
        // and an identical command means tmux/plain behavior can't diverge.
        let environment = ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
        for mode in [TerminalMultiplexingMode.tmuxPerSession, .ghosttyManagedSplits] {
            let resume = GhosttyTerminalConfig(
                launchContext: .hostSession(
                    HostTerminalSession(
                        key: .repoPath("/tmp/repo-a"),
                        directory: URL(fileURLWithPath: "/tmp/repo-a"),
                        initialCommand: "claude --resume sess-123"
                    ),
                    hooksSocketPath: nil
                ),
                environment: environment,
                terminalMultiplexingMode: mode,
                isTmuxAvailableOverride: true
            )
            let plain = GhosttyTerminalConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
                environment: environment,
                terminalMultiplexingMode: mode,
                isTmuxAvailableOverride: true
            )
            #expect(resume.command == plain.command)
        }
    }

    @Test("tmux mode falls back to login shell when tmux unavailable")
    func tmuxModeFallsBackWhenTmuxMissing() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: false
        )

        #expect(config.command == "/bin/zsh --login")
    }

    @Test("clean shell mode uses zsh without profile loading")
    func cleanShellModeUsesBareZsh() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        #expect(config.command == "/bin/zsh -f")
        #expect(config.shellProfileModeLabel == "clean")
    }

    @Test("clean zsh diagnostics install prompt readiness marker")
    func cleanZshDiagnosticsInstallPromptReadinessMarker() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
                "WORKSPACES_TERMINAL_DIAGNOSTICS": "1",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        let prompt = try #require(config.environmentVariables["PROMPT"])
        #expect(config.command == "/bin/zsh -f")
        #expect(prompt.contains("\u{1B}]0;WorkSpaces Ready\u{7}"))
        #expect(prompt.hasPrefix("%{"))
    }

    @Test("clean shell mode uses bash without profile loading")
    func cleanShellModeUsesBareBash() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/bash",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        #expect(config.command == "/bin/bash --noprofile --norc")
        #expect(config.shellProfileModeLabel == "clean")
    }

    @Test("clean bash diagnostics install prompt readiness marker")
    func cleanBashDiagnosticsInstallPromptReadinessMarker() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/bash",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
                "WORKSPACES_TERMINAL_DIAGNOSTICS": "1",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true
        )

        let prompt = try #require(config.environmentVariables["PS1"])
        #expect(config.command == "/bin/bash --noprofile --norc")
        #expect(prompt.contains("\u{1B}]0;WorkSpaces Ready\u{7}"))
        #expect(prompt.hasPrefix("\\["))
    }

    @Test("host session hook context is exported when both values are available")
    func exportsHostSessionHookContext() {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hostSessionID: hostSessionID,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )

        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == hostSessionID.uuidString)
        #expect(config.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == "/tmp/workspaces-hooks.sock")
        let commandStatusHook = config.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"]
        #expect(commandStatusHook?.hasSuffix("command-status.zsh") == true)
        if let commandStatusHook {
            #expect(FileManager.default.fileExists(atPath: commandStatusHook))
        }
    }

    @Test("host session hook context is omitted unless complete")
    func omitsIncompleteHostSessionHookContext() {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let missingSocket = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hostSessionID: hostSessionID
        )
        let missingHostID = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hooksSocketPath: "/tmp/workspaces-hooks.sock"
        )

        #expect(missingSocket.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(missingSocket.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(missingSocket.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
        #expect(missingHostID.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(missingHostID.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(missingHostID.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
    }

    @Test("Automation context exports only socket and opaque handle")
    func exportsAutomationContextOnly() {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            hostSessionID: hostSessionID,
            hooksSocketPath: "/tmp/workspaces-hooks.sock",
            automationEnvironment: AutomationTerminalEnvironment(
                socketPath: "/tmp/workspaces-automation.sock",
                handle: "opaque-handle"
            )
        )

        #expect(config.environmentVariables["WORKSPACES_AUTOMATION_SOCKET"] == "/tmp/workspaces-automation.sock")
        #expect(config.environmentVariables["WORKSPACES_AUTOMATION_HANDLE"] == "opaque-handle")
        #expect(config.environmentVariables["WORKSPACES_TILE_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_SURFACE_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == hostSessionID.uuidString)
    }

    @Test("Automation context is omitted when no automation environment is provided")
    func omitsAutomationContextWhenUnavailable() {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .ghosttyManagedSplits,
            isTmuxAvailableOverride: true,
            automationEnvironment: nil
        )

        #expect(config.environmentVariables[AutomationAPI.socketEnvironmentKey] == nil)
        #expect(config.environmentVariables[AutomationAPI.handleEnvironmentKey] == nil)
    }

    @Test("custom command config preserves explicit command without hook environment")
    func customCommandConfigPreservesExplicitCommandWithoutHookEnvironment() {
        let config = GhosttyTerminalConfig(customCommand: "/usr/local/bin/lume ssh vm-123")

        #expect(config.command == "/usr/local/bin/lume ssh vm-123")
        #expect(config.shellProfileModeLabel == "custom")
        #expect(config.environmentVariables["WORKSPACES_HOST_SESSION_ID"] == nil)
        #expect(config.environmentVariables["WORKSPACES_HOOKS_SOCKET"] == nil)
        #expect(config.environmentVariables["WORKSPACES_COMMAND_STATUS_ZSH"] == nil)
    }

    @Test("tmux mode respects clean shell override")
    func tmuxModeRespectsCleanShellOverride() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let command = try #require(config.command)
        #expect(command.contains("/bin/zsh -f -c "))
        #expect(command.contains("tmux -L workspaces new-session -A -s"))
        #expect(config.shellProfileModeLabel == "clean")
    }

    @Test("A chosen tmux session name wins over the directory derivation")
    func chosenTmuxSessionNameWinsOverDerivation() throws {
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            tmuxSessionName: "wm-repo-a-12345678-pdeadbeef"
        )

        let command = try #require(config.command)
        #expect(command.contains("new-session -A -s"))
        #expect(command.contains("'wm-repo-a-12345678-pdeadbeef'"))
    }

    @Test("A split session's launch context threads its disambiguated tmux name")
    func splitSessionLaunchContextThreadsItsName() throws {
        let directory = URL(fileURLWithPath: "/tmp/repo-a")
        let splitID = UUID()
        let splitName = TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: splitID)
        let config = GhosttyTerminalConfig(
            launchContext: .hostSession(
                HostTerminalSession(
                    id: splitID,
                    key: .repoPath(directory.path),
                    directory: directory,
                    tmuxSessionNameOverride: splitName
                ),
                hooksSocketPath: nil
            ),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let command = try #require(config.command)
        #expect(command.contains("'\(splitName)'"))
        #expect(!command.contains("'\(GhosttyTerminalConfig.tmuxSessionName(for: directory))'"))
    }

    /// Launch and probe must agree on tool paths: TmuxSessionProbe injects them even
    /// when PATH is absent, so the launch gate has to as well — otherwise a session
    /// the probe reports alive launches as a plain shell instead of reattaching.
    @Test("A missing or empty PATH still gets the probe's tool paths")
    func missingPathGetsToolPaths() {
        let toolPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let withoutPath = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh"],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )
        let emptyPath = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": ""],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        #expect(withoutPath.environmentVariables["PATH"] == toolPaths)
        #expect(emptyPath.environmentVariables["PATH"] == toolPaths)
    }

    @Test("tmux session identity is stable for a given path")
    func tmuxSessionIdentityIsStable() {
        let first = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let second = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        let different = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        #expect(first.command == second.command)
        #expect(first.command != different.command)
    }

    // MARK: - Per-tile tmux session environment

    /// The env pairs a tile-scoped launch carries, in the order the builder emits.
    private static func tileEnvironment(handle: String) -> [(key: String, value: String)] {
        [
            (key: AutomationAPI.socketEnvironmentKey, value: "/tmp/workspaces-automation.sock"),
            (key: AutomationAPI.handleEnvironmentKey, value: handle),
        ]
    }

    /// A pane inherits the tmux *server's* environment, and one server backs every
    /// session on the `-L workspaces` socket. Without per-session wiring, the
    /// second workspace's tile runs with the first workspace's handle and its
    /// in-tile CLI verbs mutate the wrong tile.
    @Test("tmux launch seeds this tile's automation handle into its own session")
    func tmuxLaunchSeedsAutomationHandleIntoSession() {
        let script = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-b-00000000",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            sessionEnvironment: Self.tileEnvironment(handle: "handle-b")
        )

        #expect(script.contains("exec tmux -L workspaces new-session -A -s 'wm-repo-b-00000000' -c '/tmp/repo-b'"))
        #expect(script.contains("-e '\(AutomationAPI.handleEnvironmentKey)=handle-b'"))
        #expect(script.contains("-e '\(AutomationAPI.socketEnvironmentKey)=/tmp/workspaces-automation.sock'"))
    }

    /// The whole script travels as one `-c` argument, so the config's escaping has
    /// to survive it — the value the CLI resolves its caller from must still be
    /// recoverable from the launch command.
    @Test("The composed launch command carries the tile's handle and hook context")
    func composedLaunchCommandCarriesTileEnvironment() throws {
        let hostSessionID = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            tmuxSupportsSessionEnvironmentFlagOverride: true,
            hostSessionID: hostSessionID,
            hooksSocketPath: "/tmp/workspaces-hooks.sock",
            automationEnvironment: AutomationTerminalEnvironment(
                socketPath: "/tmp/workspaces-automation.sock",
                handle: "handle-b"
            ),
            tmuxSessionName: "wm-repo-b-00000000"
        )

        let command = try #require(config.command)
        #expect(command.contains("'\(AutomationAPI.handleEnvironmentKey)=handle-b'"))
        #expect(command.contains("'\(AutomationAPI.socketEnvironmentKey)=/tmp/workspaces-automation.sock'"))
        #expect(command.contains("'WORKSPACES_HOST_SESSION_ID=\(hostSessionID.uuidString)'"))
        #expect(command.contains("'WORKSPACES_HOOKS_SOCKET=/tmp/workspaces-hooks.sock'"))
    }

    /// The defect in issue #1257, at the seam that causes it: two tiles launching
    /// against the same tmux server must not carry each other's handle.
    @Test("Two tiles' tmux launches carry only their own handle")
    func tmuxLaunchesDoNotCrossTileHandles() {
        let workspaceA = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-a",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            sessionEnvironment: Self.tileEnvironment(handle: "handle-a")
        )
        let workspaceB = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-b",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            sessionEnvironment: Self.tileEnvironment(handle: "handle-b")
        )

        #expect(workspaceA.contains("handle-a"))
        #expect(!workspaceA.contains("handle-b"))
        #expect(workspaceB.contains("handle-b"))
        #expect(!workspaceB.contains("handle-a"))
    }

    /// The create path's first pane spawns as part of `new-session`, before the
    /// chained commands run — so every seeded pair has to ride `new-session -e`
    /// itself. A pair that drifted past the `\;` separator would leave a freshly
    /// created tile's own first shell without its handle, which is the bug.
    @Test("Seeded pairs ride new-session itself, ahead of the chained commands")
    func seededPairsRideNewSessionBeforeChainedCommands() throws {
        let script = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-b-00000000",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            sessionEnvironment: Self.tileEnvironment(handle: "handle-b")
        )

        let firstChained = try #require(script.range(of: " \\; "))
        let newSessionArguments = script[..<firstChained.lowerBound]
        for pair in Self.tileEnvironment(handle: "handle-b") {
            #expect(newSessionArguments.contains("-e '\(pair.key)=\(pair.value)'"))
        }
    }

    /// `new-session -A` attaching a session that survived an earlier launch ignores
    /// `-e`, so the surviving session still names the recorded launch's handle. The
    /// chained `set-environment` runs after create-or-attach on either path, with
    /// no probe-then-attach window another launch could create the session in.
    @Test("Reattach reseeds a surviving session with this launch's handle")
    func reattachReseedsSurvivingSessionEnvironment() throws {
        let script = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-b-00000000",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            sessionEnvironment: Self.tileEnvironment(handle: "handle-current-launch")
        )

        let reseed =
            "\\; set-environment -t '=wm-repo-b-00000000' "
            + "'\(AutomationAPI.handleEnvironmentKey)' 'handle-current-launch'"
        let attachRange = try #require(script.range(of: "new-session -A"))
        let reseedRange = try #require(script.range(of: reseed))

        #expect(attachRange.lowerBound < reseedRange.lowerBound)
        #expect(!script.contains("has-session"))
    }

    /// `new-session -e` arrived in tmux 3.2. Handing it to an older tmux is not a
    /// degraded launch — tmux rejects the flag and the pane never comes up — so the
    /// pre-3.2 shape drops the `-e` pairs and keeps the chained `set-environment`,
    /// which every tmux understands.
    @Test("A tmux without new-session -e seeds the session after create instead")
    func tmuxWithoutSessionEnvironmentFlagSeedsAfterCreate() throws {
        let script = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-b-00000000",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
            sessionEnvironment: Self.tileEnvironment(handle: "handle-b"),
            seedsEnvironmentOnCreate: false
        )

        #expect(script.hasPrefix("exec tmux -L workspaces new-session -A -s 'wm-repo-b-00000000' -c '/tmp/repo-b' \\;"))
        #expect(!script.contains(" -e "))
        for pair in Self.tileEnvironment(handle: "handle-b") {
            let reseed = "\\; set-environment -t '=wm-repo-b-00000000' '\(pair.key)' '\(pair.value)'"
            #expect(script.contains(reseed))
        }
    }

    /// The two shapes differ only in the `-e` pairs: the same keys, the same values,
    /// the same session, so a downgrade costs a created session's first pane its
    /// environment and nothing else.
    @Test("The pre-3.2 shape is the 3.2+ shape minus its new-session -e pairs")
    func preThreeTwoShapeIsTheModernShapeWithoutSeeding() {
        func script(seedsEnvironmentOnCreate: Bool) -> String {
            GhosttyTerminalConfig.tmuxLaunchScript(
                sessionName: "wm-repo-b-00000000",
                workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
                sessionEnvironment: Self.tileEnvironment(handle: "handle-b"),
                seedsEnvironmentOnCreate: seedsEnvironmentOnCreate
            )
        }

        var stripped = script(seedsEnvironmentOnCreate: true)
        for pair in Self.tileEnvironment(handle: "handle-b") {
            stripped = stripped.replacingOccurrences(of: " -e '\(pair.key)=\(pair.value)'", with: "")
        }
        #expect(stripped == script(seedsEnvironmentOnCreate: false))
    }

    /// The version answer has to reach the composed launch command, not just the
    /// script builder — the config is what a surface actually launches.
    @Test("The composed launch command follows the resolved tmux capability")
    func composedLaunchCommandFollowsResolvedTmuxCapability() throws {
        func command(supportsSessionEnvironmentFlag: Bool) throws -> String {
            let config = GhosttyTerminalConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
                environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
                terminalMultiplexingMode: .tmuxPerSession,
                isTmuxAvailableOverride: true,
                tmuxSupportsSessionEnvironmentFlagOverride: supportsSessionEnvironmentFlag,
                automationEnvironment: AutomationTerminalEnvironment(
                    socketPath: "/tmp/workspaces-automation.sock",
                    handle: "handle-b"
                ),
                tmuxSessionName: "wm-repo-b-00000000"
            )
            return try #require(config.command)
        }

        // The script is re-quoted into the shell's `-c` argument, so assert on the
        // forms that survive that layer: `KEY=VALUE` is the `-e` pair, `'KEY'` and
        // `'VALUE'` as separate words are the chained `set-environment`.
        let seeded = try command(supportsSessionEnvironmentFlag: true)
        #expect(seeded.contains("'\(AutomationAPI.handleEnvironmentKey)=handle-b'"))
        #expect(seeded.contains("set-environment"))

        let unseeded = try command(supportsSessionEnvironmentFlag: false)
        #expect(!unseeded.contains("\(AutomationAPI.handleEnvironmentKey)=handle-b"))
        #expect(unseeded.contains("set-environment"))
        #expect(unseeded.contains("'\(AutomationAPI.handleEnvironmentKey)'"))
        #expect(unseeded.contains("'handle-b'"))
    }

    @Test("A tmux launch with no tile-scoped environment stays a bare attach-or-create")
    func tmuxLaunchWithoutTileEnvironmentStaysBare() throws {
        let script = GhosttyTerminalConfig.tmuxLaunchScript(
            sessionName: "wm-repo-a",
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            sessionEnvironment: []
        )
        let config = GhosttyTerminalConfig(
            workingDirectory: URL(fileURLWithPath: "/tmp/repo-a"),
            environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true
        )

        #expect(script == "exec tmux -L workspaces new-session -A -s 'wm-repo-a' -c '/tmp/repo-a'")
        let command = try #require(config.command)
        #expect(!command.contains("set-environment"))
    }

    /// The script is interpolated into a shell command that is itself wrapped as a
    /// single `-c` argument, so quoting has to survive two layers. Parsing the
    /// composed command with a real shell and a `tmux` stand-in is the only check
    /// that binds what tmux actually receives — a substring assertion cannot tell
    /// a correctly escaped apostrophe from one that ended the quoting context.
    @Test("Adversarial values reach tmux as single argv elements")
    func adversarialValuesSurviveBothQuotingLayers() throws {
        let sessionName = "wm-o'brien's repo"
        let workingDirectory = URL(fileURLWithPath: "/tmp/o'brien repo")
        let handle = "han'dle \"x\" $y `z`"
        let config = GhosttyTerminalConfig(
            workingDirectory: workingDirectory,
            environment: [
                "SHELL": "/bin/sh",
                "PATH": "/usr/bin:/bin",
                "WORKSPACES_SHELL_PROFILE_MODE": "clean",
            ],
            terminalMultiplexingMode: .tmuxPerSession,
            isTmuxAvailableOverride: true,
            tmuxSupportsSessionEnvironmentFlagOverride: true,
            automationEnvironment: AutomationTerminalEnvironment(
                socketPath: "/tmp/auto.sock",
                handle: handle
            ),
            tmuxSessionName: sessionName
        )

        let argv = try Self.argvHandedToTmux(byRunning: try #require(config.command))

        #expect(argv.contains(sessionName))
        #expect(argv.contains(workingDirectory.path))
        #expect(argv.contains("\(AutomationAPI.handleEnvironmentKey)=\(handle)"))
        #expect(argv.contains(handle))
        #expect(argv.contains("=\(sessionName)"))
        // The separator tmux splits its command sequence on.
        #expect(argv.contains(";"))
    }

    /// Runs `command` under `/bin/sh` with a `tmux` stand-in first on PATH that
    /// prints each argument it receives on its own line, and returns those lines
    /// for the first invocation. `exec` in the script means that invocation is the
    /// whole of it.
    private static func argvHandedToTmux(byRunning command: String) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmux-argv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stub = directory.appendingPathComponent("tmux")
        try "#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": directory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Killing the child at the deadline closes the pipe, so the read below is
        // bounded by the same budget as the wait.
        let killSwitch = armKillSwitch(for: process, after: childProcessBudgetSeconds)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killSwitch.cancel()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Deadline for the stub round trip above, sized from this machine's measured
    /// cost of launching a child and getting an answer back rather than from a fixed
    /// wall clock — the policy in `WorkspaceManagerTests/Helpers/LaunchBudget`,
    /// applied at the one call site in this target that supervises a process (the
    /// two test targets cannot share source). Floored so a fast machine still fails
    /// fast, capped so a pathological baseline cannot hang the run.
    private static var childProcessBudgetSeconds: TimeInterval {
        min(60, max(5, launchRoundTripSeconds * 20))
    }

    /// One trivial launch-to-exit round trip, measured once. A machine the probe
    /// cannot run on is not evidence of a fast one, so it reads as slow.
    private static let launchRoundTripSeconds: TimeInterval = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        guard (try? process.run()) != nil else { return 20 }
        let killSwitch = armKillSwitch(for: process, after: 90)
        process.waitUntilExit()
        killSwitch.cancel()
        return max(Date().timeIntervalSince(started), 0.05)
    }()

    /// Terminates `process` once `seconds` elapse. Cancel it once the child is
    /// reaped: a stub that never exits should fail its test on a budget, not hang
    /// the suite.
    private static func armKillSwitch(for process: Process, after seconds: TimeInterval) -> DispatchWorkItem {
        let killSwitch = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: killSwitch)
        return killSwitch
    }

    @Test("Only tile-scoped keys are seeded into the session environment")
    func onlyTileScopedKeysAreSeeded() {
        let seeded = GhosttyTerminalConfig.tileScopedEnvironment(from: [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            AutomationAPI.handleEnvironmentKey: "handle-b",
            "WORKSPACES_HOST_SESSION_ID": "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31",
        ])

        #expect(seeded.map(\.key) == [AutomationAPI.handleEnvironmentKey, "WORKSPACES_HOST_SESSION_ID"])
    }

    /// Dictionary iteration order is unstable; the launch command must not be, or
    /// restore comparisons and command-equality assertions become flaky.
    @Test("Seeded environment ordering is deterministic")
    func seededEnvironmentOrderingIsDeterministic() {
        func config() -> GhosttyTerminalConfig {
            GhosttyTerminalConfig(
                workingDirectory: URL(fileURLWithPath: "/tmp/repo-b"),
                environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
                terminalMultiplexingMode: .tmuxPerSession,
                isTmuxAvailableOverride: true,
                tmuxSupportsSessionEnvironmentFlagOverride: true,
                hostSessionID: UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!,
                hooksSocketPath: "/tmp/workspaces-hooks.sock",
                automationEnvironment: AutomationTerminalEnvironment(
                    socketPath: "/tmp/workspaces-automation.sock",
                    handle: "handle-b"
                ),
                tmuxSessionName: "wm-repo-b-00000000"
            )
        }

        #expect(config().command == config().command)
    }
}
