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
            // #1265's verbs shipped at top level; scripts/api-select-smoke.sh drives
            // `workspaces wait` that way, so grouping them may not break the spelling.
            (
                ["wait", "--for", "surface_attached"],
                ["automation", "wait", "--for", "surface_attached"]
            ),
            (["focus", "--json"], ["automation", "focus", "--json"]),
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

    @Test("Help states the real activation condition, not just a running app")
    func helpNamesOperatorCredentialCondition() {
        let help = CLIVerbCatalog.helpText
        #expect(help.contains("Automation Operator experiment enabled"))
        #expect(help.contains("WORKSPACES_AUTOMATION_OPERATOR=1"))
        #expect(help.contains("derive from the app only when the operator credential is readable"))
        // "the app is running" alone would overstate when the two-plane view engages.
        #expect(!help.contains("When the app is running,"))
    }

    /// The snapshot below interpolates the same expression the help text does, so by itself it
    /// would keep passing if the prose and the constant drifted apart. This reads the figure back
    /// out of the rendered help and compares it to the deadline the probe hands the socket, so the
    /// two spellings of the bound cannot disagree.
    @Test("The probe bound printed in help is the constant the probe uses")
    func helpProbeBoundTracksTheConstant() throws {
        let help = CLIVerbCatalog.helpText
        let match = try #require(help.firstMatch(of: try Regex("bounded at ([0-9]+(?:\\.[0-9]+)?)s")))
        let printed = try #require(match[1].substring.flatMap { Double($0) })
        #expect(printed == CLIAppProbe.deadline)
    }

    /// The bound is SO_RCVTIMEO/SO_SNDTIMEO on the probe socket — per blocking syscall, not a
    /// budget for the whole call — so help must not promise a ceiling it cannot hold.
    @Test("Help states the per-read socket bound, not a whole-call ceiling")
    func helpDescribesPerReadBound() {
        // Line wrapping is a rendering choice; the sentence is the contract.
        let unwrapped = CLIVerbCatalog.helpText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(unwrapped.contains("per socket read rather than as a whole-call budget"))
        #expect(!unwrapped.contains("ceiling"))
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
              workspaces ws launch <workspace> [--cmd "command"] [--name <label>] [--json]
              workspaces ws read <handle|workspace> [--lines N] [--json]
              workspaces ws send <handle|workspace> --text "text" [--enter] [--json]
              workspaces open <workspace> [--cmd "command"]
              workspaces run <workspace> -- <command...>
              workspaces run <workspace> --cmd "command"
              workspaces resume
              workspaces status <workspace> [--watch] [--interval <seconds>]
              workspaces recent
              workspaces doctor

            Automation commands (operator scope; require the app running with the
            Automation Operator experiment enabled — or WORKSPACES_AUTOMATION_OPERATOR=1
            — which is what mints the operator credential these verbs read):
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
              workspaces automation workspace archive <workspace-id> [--teardown] [--json]
              workspaces automation wait --for <condition> [--surface-id <id>] [--workspace-id <id>] [--pattern <regex>] [--timeout-ms <n>] [--json]
              workspaces automation focus [--json]

            Compatibility:
              'surface', 'tile', 'input', 'window', 'workspace', 'wait', and 'focus'
              still work as top-level verbs and mean 'automation <verb>'.

            Two planes:
              'ws' and 'repo' manage the CLI-local plane and work without the app;
              'automation workspace' drives the running app. 'ws list' and 'repo list'
              derive from the app only when the operator credential is readable —
              the app running without it leaves them showing the CLI-local plane
              alone, and the app cannot see what they list. That derivation
              costs one short probe of the app, bounded at \(CLIAppProbe.deadlineDescription) per socket
              read rather than as a whole-call budget. A probe that misses falls
              back to the CLI-local plane, and says which way it missed on an
              interactive terminal (or under WORKSPACES_CLI_VERBOSE=1).

            Detached sessions:
              'ws launch' returns a handle instead of attaching. The handle is a tmux
              session on the app's own '-L workspaces' socket, named the way the app
              names that workspace's terminal — so opening the workspace in the app
              (tmux-per-session mode) attaches to the agent already running there
              rather than starting a second one. '--name <label>' makes a sibling
              session instead. 'ws read' and 'ws send' take either a handle or a
              workspace selector. Set WORKSPACES_TMUX_SOCKET_LABEL to work against a
              server other than the app's.

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
