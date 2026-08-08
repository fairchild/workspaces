import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLIVerbCatalog")
struct CLIVerbCatalogTests {
    @Test(
        "Top-level automation aliases canonicalize into the grouped form",
        arguments: [
            (["surface", "list", "--json"], ["automation", "surface", "list", "--json"]),
            (["tile", "focus", "--left"], ["automation", "tile", "focus", "--left"]),
            (["tile", "split", "--down"], ["automation", "tile", "split", "--down"]),
            (["input", "write", "hello", "--submit"], ["automation", "input", "write", "hello", "--submit"]),
            (["window", "list"], ["automation", "window", "list"]),
            (["window", "snapshot", "--out", "x.png"], ["automation", "window", "snapshot", "--out", "x.png"]),
            (["workspace", "list", "--json"], ["automation", "workspace", "list", "--json"]),
            (["workspace", "create", "repo-id", "name"], ["automation", "workspace", "create", "repo-id", "name"]),
        ]
    )
    func aliasCanonicalization(input: [String], expected: [String]) {
        #expect(CLIVerbCatalog.canonicalArguments(input) == expected)
    }

    @Test(
        "Non-alias argument vectors pass through unchanged",
        arguments: [
            ["automation", "health"],
            ["automation", "workspace", "list", "--json"],
            ["ws", "list"],
            ["ws", "new", "repo", "name"],
            ["repo", "add", "/tmp/repo"],
            ["open", "repo/name"],
            ["doctor"],
            ["help"],
            ["nonsense", "surface"],
            [],
        ]
    )
    func passthrough(arguments: [String]) {
        #expect(CLIVerbCatalog.canonicalArguments(arguments) == arguments)
    }

    @Test("Every automation verb and alias spelling is a reserved command")
    func reservedCommandsCoverAllSpellings() {
        for verb in CLIVerbCatalog.topLevelAutomationAliases {
            #expect(CLIVerbCatalog.reservedCommands.contains(verb))
        }
        for verb in CLIVerbCatalog.localVerbs {
            #expect(CLIVerbCatalog.reservedCommands.contains(verb))
        }
        #expect(CLIVerbCatalog.reservedCommands.contains("automation"))
        #expect(CLIVerbCatalog.reservedCommands.contains("help"))
        #expect(CLIVerbCatalog.reservedCommands.contains("--help"))
        #expect(CLIVerbCatalog.reservedCommands.contains("-h"))
    }

    @Test("Aliases are exactly the automation verbs that historically sat at top level")
    func aliasSetShape() {
        #expect(CLIVerbCatalog.topLevelAutomationAliases.isSubset(of: CLIVerbCatalog.automationVerbs))
        #expect(!CLIVerbCatalog.topLevelAutomationAliases.contains("health"))
        #expect(!CLIVerbCatalog.topLevelAutomationAliases.contains("context"))
        #expect(CLIVerbCatalog.localVerbs.isDisjoint(with: CLIVerbCatalog.topLevelAutomationAliases))
    }

    @Test("Help groups every socket verb under 'workspaces automation'")
    func helpGroupsAutomationVerbs() {
        let help = CLIVerbCatalog.helpText
        for verb in CLIVerbCatalog.automationVerbs {
            #expect(help.contains("workspaces automation \(verb)"))
        }
        // No usage line resurrects the ungrouped operator spellings; the compatibility
        // note is the only mention of the bare verbs.
        for verb in CLIVerbCatalog.topLevelAutomationAliases {
            #expect(!help.contains("\n  workspaces \(verb) "))
        }
    }

    @Test("Help text snapshot")
    func helpSnapshot() {
        let expected = """
            WorkSpaces CLI

            Usage:
              workspaces
              workspaces .
              workspaces /path/to/repo

            Local commands (CLI-local state; no running app required):
              workspaces repo add <path>
              workspaces repo list
              workspaces ws new <repo> <name>
              workspaces ws list
              workspaces ws path <workspace>
              workspaces ws race <repo> <prompt...> [--n 3] [--cmd "claude"] [--name <slug>] [--no-launch]
              workspaces open <workspace> [--cmd "command"]
              workspaces run <workspace> -- <command...>
              workspaces run <workspace> --cmd "command"
              workspaces resume
              workspaces status <workspace> [--watch] [--interval <seconds>]
              workspaces recent
              workspaces doctor

            Automation commands (operator scope; require a running app with the
            automation experiments enabled):
              workspaces automation health
              workspaces automation context --json
              workspaces automation surface list --json
              workspaces automation tile focus --left|--right|--up|--down|--next|--previous
              workspaces automation tile split --left|--right|--up|--down
              workspaces automation tile close
              workspaces automation input write <text> [--submit]
              workspaces automation window list [--json]
              workspaces automation window snapshot --out <path> [--window <id>]
              workspaces automation workspace list [--json]
              workspaces automation workspace select <workspace-id> [--json]
              workspaces automation workspace create <repo-id> <name> [--provider <id>] [--guest-os <linux|macos>] [--json]
              workspaces automation workspace archive <workspace-id> [--json]

            Compatibility:
              'surface', 'tile', 'input', 'window', and 'workspace' still work as
              top-level verbs and mean 'automation <verb>'.

            Two planes:
              'ws' and 'repo' manage the CLI-local plane and work without the app;
              'automation workspace' drives the running app. When the app is running,
              'ws list' and 'repo list' derive from the app and label CLI-local-only
              entries.

            Launch behavior:
              - no args: open the WorkSpaces app
              - path arg: open the app and focus the matching workspace or repo

            Workspace selectors:
              - UUID
              - <repo>/<workspace>
              - workspace name (if unique)
            """
        #expect(CLIVerbCatalog.helpText == expected)
    }
}
