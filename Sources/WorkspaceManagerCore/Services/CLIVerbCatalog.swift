//
//  CLIVerbCatalog.swift
//  WorkspaceManagerCore
//
//  The `workspaces` CLI's verb table: which verbs are local (CLI-local state, no running
//  app) and which are automation verbs (operator scope over the app's socket), plus the
//  canonicalization that maps the compatibility top-level spellings onto the grouped
//  `automation <verb>` form and the rendered `workspaces help` text.
//

import Foundation

public enum CLIVerbCatalog {
    /// Verbs that operate on CLI-local state or the local filesystem; no running app required.
    public static let localVerbs: Set<String> = [
        "repo", "ws", "open", "run", "resume", "status", "recent", "doctor",
    ]

    /// Grouped subcommands of `workspaces automation ...` — every verb that talks to the
    /// app's automation socket.
    public static let automationVerbs: Set<String> = [
        "health", "context", "surface", "tile", "input", "window", "workspace", "wait", "focus",
    ]

    /// Top-level spellings kept as compatibility aliases for the grouped automation verbs
    /// (`workspaces workspace list` means `workspaces automation workspace list`).
    public static let topLevelAutomationAliases: Set<String> = [
        "surface", "tile", "input", "window", "workspace", "wait", "focus",
    ]

    /// Every first-argument spelling the CLI claims, so path-launch dispatch never swallows
    /// a verb even when a sibling folder shares its name.
    public static let reservedCommands: Set<String> = {
        var commands: Set<String> = ["help", "--help", "-h", "automation"]
        commands.formUnion(localVerbs)
        commands.formUnion(topLevelAutomationAliases)
        return commands
    }()

    /// Rewrites a top-level automation alias into the canonical grouped form; every other
    /// argument vector passes through unchanged.
    public static func canonicalArguments(_ arguments: [String]) -> [String] {
        guard let first = arguments.first, topLevelAutomationAliases.contains(first) else {
            return arguments
        }
        return ["automation"] + arguments
    }

    /// Rendered help. The probe deadline interpolates from `CLIAppProbe.deadline` — the same
    /// constant the probe hands the socket — so the figure a caller reads before scripting a
    /// loop cannot drift from the one the socket gets.
    public static let helpText = """
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
          workspaces automation workspace note <workspace-id> --text "text" | --clear [--json]
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

        Launch behavior:
          - no args: open the WorkSpaces app
          - path arg: open the app and focus the matching workspace or repo

        Workspace selectors:
          - UUID
          - <repo>/<workspace>
          - workspace name (if unique)
        """
}
