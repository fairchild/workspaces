//
//  GhosttyThemeConfigTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyThemeConfig")
struct GhosttyThemeConfigTests {
    @Test("No selection produces no theme value")
    func emptyPairHasNoValue() {
        #expect(GhosttyThemeConfig.themeValue(lightTheme: "", darkTheme: "") == nil)
        #expect(
            GhosttyThemeConfig.configContents(lightTheme: "", darkTheme: "")
                == "scrollbar = system\nmouse-scroll-multiplier = precision:0.7,discrete:1\n"
        )
    }

    @Test("Both slots set produce the dual light/dark value")
    func bothSlotsSet() {
        #expect(
            GhosttyThemeConfig.themeValue(lightTheme: "Catppuccin Latte", darkTheme: "Dracula")
                == "light:Catppuccin Latte,dark:Dracula"
        )
        #expect(
            GhosttyThemeConfig.configContents(lightTheme: "Nord", darkTheme: "Dracula")
                == "scrollbar = system\nmouse-scroll-multiplier = precision:0.7,discrete:1\n"
                + "theme = light:Nord,dark:Dracula\n"
        )
    }

    @Test("An unset slot is filled with the built-in fallback to keep the dual form valid")
    func unsetSlotFallsBackToBuiltin() {
        #expect(
            GhosttyThemeConfig.themeValue(lightTheme: "", darkTheme: "Dracula")
                == "light:Builtin Light,dark:Dracula"
        )
        #expect(
            GhosttyThemeConfig.themeValue(lightTheme: "Catppuccin Latte", darkTheme: "")
                == "light:Catppuccin Latte,dark:Builtin Dark"
        )
    }

    @Test("Whitespace around theme names is trimmed")
    func trimsWhitespace() {
        #expect(
            GhosttyThemeConfig.themeValue(lightTheme: "  Nord  ", darkTheme: " Dracula ")
                == "light:Nord,dark:Dracula"
        )
    }

    @Test("Config file lives under <dataDir>/ghostty/workspaces.config")
    func configFileURLLayout() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = try GhosttyThemeConfig.configFileURL(
            environment: ["WORKSPACES_DATA_DIR": dataDir.path]
        )
        #expect(url.lastPathComponent == "workspaces.config")
        #expect(url.deletingLastPathComponent().lastPathComponent == "ghostty")
        #expect(url.path.hasPrefix(dataDir.path))
    }

    @Test("Writing always persists the WorkSpaces-managed Ghostty config file")
    func writeConfigFile() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let environment = ["WORKSPACES_DATA_DIR": dataDir.path]

        let url = try GhosttyThemeConfig.writeConfigFile(
            lightTheme: "Nord",
            darkTheme: "Dracula",
            environment: environment
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(
            contents
                == "scrollbar = system\nmouse-scroll-multiplier = precision:0.7,discrete:1\n"
                + "theme = light:Nord,dark:Dracula\n"
        )

        let unthemed = try GhosttyThemeConfig.writeConfigFile(
            lightTheme: "",
            darkTheme: "",
            environment: environment
        )
        #expect(unthemed == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
