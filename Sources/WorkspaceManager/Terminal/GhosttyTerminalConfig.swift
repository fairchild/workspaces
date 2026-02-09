//
//  GhosttyTerminalConfig.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

struct GhosttyTerminalConfig {
    let fontSize: Float32
    let workingDirectory: String
    let command: String?
    let environmentVariables: [String: String]

    init(workingDirectory: URL, fontSize: Float32 = 13) {
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory.path

        var environment = ProcessInfo.processInfo.environment
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
        self.command = "\(shell) --login"
        self.environmentVariables = environment
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
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

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
