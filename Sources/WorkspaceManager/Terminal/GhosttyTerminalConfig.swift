//
//  GhosttyTerminalConfig.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

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

    init(
        workingDirectory: URL,
        fontSize: Float32 = 13,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        terminalMultiplexingMode: TerminalMultiplexingMode? = nil,
        isTmuxAvailableOverride: Bool? = nil
    ) {
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory.path

        var environment = environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"

        if let path = environment["PATH"] {
            environment["PATH"] = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                path,
            ].joined(separator: ":")
        }

        let shell = environment["SHELL"] ?? "/bin/zsh"
        let shellProfileMode = ShellProfileMode.resolve(from: environment)
        let mode = terminalMultiplexingMode ?? TerminalMultiplexingMode.resolve()
        let tmuxAvailable =
            isTmuxAvailableOverride
            ?? Self.isExecutableAvailable(
                "tmux",
                inPath: environment["PATH"]
            )

        if mode == .tmuxPerSession, tmuxAvailable {
            let tmuxSessionName = Self.tmuxSessionName(for: workingDirectory)
            let quotedSession = Self.singleQuoted(tmuxSessionName)
            let quotedWorkingDirectory = Self.singleQuoted(workingDirectory.path)
            let tmuxScript = "exec tmux -L workspaces new-session -A -s \(quotedSession) -c \(quotedWorkingDirectory)"
            self.command = Self.shellInvocation(shell: shell, profileMode: shellProfileMode, command: tmuxScript)
        } else {
            self.command = Self.shellInvocation(shell: shell, profileMode: shellProfileMode)
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

    private static func tmuxSessionName(for directory: URL) -> String {
        let normalizedPath = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let baseComponent = directory.lastPathComponent.isEmpty ? "session" : directory.lastPathComponent
        let sanitizedBase = sanitizeSessionComponent(baseComponent)
        let hash = fnv1a64(normalizedPath)
        let hashPrefix = String(format: "%016llx", hash).prefix(8)
        return "wm-\(sanitizedBase)-\(hashPrefix)"
    }

    private static func sanitizeSessionComponent(_ value: String) -> String {
        let transformed = value.lowercased().map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        let collapsed = String(transformed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if collapsed.isEmpty {
            return "session"
        }

        return String(collapsed.prefix(20))
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01b3
        }
        return hash
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
