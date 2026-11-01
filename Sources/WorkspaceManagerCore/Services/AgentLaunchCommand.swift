//
//  AgentLaunchCommand.swift
//  WorkspaceManagerCore
//
//  Reads a launch command closely enough to know which conversation it starts, and
//  composes the command that continues one. A launch that names its conversation up
//  front can be found again without watching hooks or guessing from a directory. Only
//  a plain `claude` invocation is touched; anything else runs exactly as written.
//

import Foundation

/// The conversation a launch started, and what the caller asked for.
public struct AgentLaunchIdentity: Codable, Sendable, Equatable {
    public let conversationID: String
    public let requestedModel: String?
    public let requestedEffort: String?

    public init(conversationID: String, requestedModel: String?, requestedEffort: String?) {
        self.conversationID = conversationID
        self.requestedModel = requestedModel
        self.requestedEffort = requestedEffort
    }
}

public enum AgentLaunchCommand {
    public struct Plan: Sendable, Equatable {
        /// What the session runs: the caller's command, naming its conversation.
        public let command: String?
        /// `nil` for anything other than a plain `claude` invocation.
        public let identity: AgentLaunchIdentity?
    }

    /// Effort levels `claude --effort` accepts. A resume command is typed into a shell, so
    /// a stored value only reaches one after matching this table.
    static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// Flags that start something other than one new conversation this launch can name:
    /// another conversation, a one-shot run, or a session somewhere else.
    private static let unnameableFlags: Set<String> = [
        "--continue", "-c", "--print", "-p", "--fork-session", "--bg", "--background",
        "--from-pr", "--cloud", "--desktop",
    ]

    /// Flags that name one conversation.
    static let conversationFlags: Set<String> = ["--session-id", "--resume", "-r"]

    /// Words that make the invocation a management command rather than a session.
    private static let subcommands: Set<String> = [
        "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs",
        "mcp", "plugin", "plugins", "purge", "respawn", "rm", "setup-token", "stop", "update",
    ]

    /// Inserts `--session-id` right after the command word, so it stays in front of a
    /// trailing prompt or a `--` that ends the options. A command already naming its
    /// conversation keeps that id.
    public static func plan(
        command: String?,
        newConversationID: () -> String = { UUID().uuidString.lowercased() }
    ) -> Plan {
        guard let command, let parsed = parse(command) else {
            return Plan(command: command, identity: nil)
        }
        if let existing = parsed.conversationID {
            return Plan(
                command: command,
                identity: AgentLaunchIdentity(
                    conversationID: existing,
                    requestedModel: parsed.model,
                    requestedEffort: parsed.effort
                )
            )
        }
        let conversationID = newConversationID()
        var named = command
        named.insert(contentsOf: " --session-id \(conversationID)", at: parsed.insertionPoint)
        return Plan(
            command: named,
            identity: AgentLaunchIdentity(
                conversationID: conversationID,
                requestedModel: parsed.model,
                requestedEffort: parsed.effort
            )
        )
    }

    /// `claude --resume <id>`, plus the effort the conversation last ran at, which claude
    /// does not restore on its own (it restores the model and the permission mode, so
    /// neither is passed). Resume brings back identity and never authority, and the
    /// string is typed into a shell, so both values come through a shape check here
    /// rather than being repaired or escaped: `nil` for an id that is not a UUID.
    public static func claudeResume(conversationID: String, effort: String?) -> String? {
        guard UUID(uuidString: conversationID) != nil else { return nil }
        guard let effort, effortLevels.contains(effort) else {
            return "claude --resume \(conversationID)"
        }
        return "claude --resume \(conversationID) --effort \(effort)"
    }

    /// The resume command for a recorded conversation with a transcript, at the effort its
    /// last turn ran at, which beats the launch's request after a change made mid-session.
    public static func claudeResume(identity: AgentLaunchIdentity, transcript: URL) -> String? {
        claudeResume(
            conversationID: identity.conversationID,
            effort: ClaudeTranscriptTurn.last(in: transcript)?.effort ?? identity.requestedEffort
        )
    }

    public static func isKnownEffort(_ effort: String) -> Bool {
        effortLevels.contains(effort)
    }

    // MARK: - Reading

    private struct Parsed {
        let insertionPoint: String.Index
        let model: String?
        let effort: String?
        let conversationID: String?
    }

    private static func parse(_ command: String) -> Parsed? {
        guard let words = ShellWords.split(command) else { return nil }
        var index = 0
        while index < words.count, let name = assignmentName(words[index].text) {
            // A launch that picks its own config directory also picks where its transcript
            // lands, which is a place nothing here would look.
            guard name != "CLAUDE_CONFIG_DIR" else { return nil }
            index += 1
        }
        guard index < words.count,
            URL(fileURLWithPath: words[index].text).lastPathComponent == "claude"
        else { return nil }
        let commandWord = words[index]
        let arguments = Array(words[(index + 1)...]).map(\.text)
        if let first = arguments.first, subcommands.contains(first) { return nil }

        var model: String?
        var effort: String?
        var conversationID: String?

        var position = 0
        while position < arguments.count {
            let argument = arguments[position]
            if argument == "--" { break }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let flag = parts.first ?? argument
            func value() -> String? {
                if parts.count == 2 { return parts[1] }
                position += 1
                return position < arguments.count ? arguments[position] : nil
            }
            if unnameableFlags.contains(flag) { return nil }
            switch flag {
            case "--model":
                model = value().flatMap(safeToken)
            case "--effort":
                effort = value().flatMap(safeToken)
            case _ where conversationFlags.contains(flag):
                // A bare `--resume` opens a picker, only a UUID names one conversation, and
                // two of them leave claude to pick or refuse.
                guard conversationID == nil, let id = value(), UUID(uuidString: id) != nil else { return nil }
                conversationID = id
            default:
                break
            }
            position += 1
        }
        return Parsed(
            insertionPoint: commandWord.end,
            model: model,
            effort: effort,
            conversationID: conversationID
        )
    }

    private static func assignmentName(_ word: String) -> String? {
        guard let separator = word.firstIndex(of: "=") else { return nil }
        let name = word[..<separator]
        guard let first = name.first, first.isLetter || first == "_",
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        return String(name)
    }

    /// A value worth recording: it ends up in a record other processes read back.
    private static func safeToken(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 64,
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || "._:-[]".contains($0))
            })
        else { return nil }
        return value
    }
}

/// Splits a shell command into words without running it, for the one question the launch
/// path asks: is this a single simple command, and where does each word end.
enum ShellWords {
    struct Word: Equatable {
        let text: String
        let end: String.Index
    }

    /// `nil` for anything a shell would treat as more than one simple command, for
    /// unbalanced quoting, or for a double-quoted expansion that could become an option.
    /// One further along, as in a prompt, changes a word's value and nothing else.
    static func split(_ command: String) -> [Word]? {
        var words: [Word] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var index = command.startIndex

        // Braces and globs count: a shell expands them before claude sees a word, so an
        // unquoted one can hide a flag.
        func isOperator(_ character: Character) -> Bool {
            ";&|<>()`\n#${}*?[]".contains(character)
        }

        while index < command.endIndex {
            let character = command[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    let next = command.index(after: index)
                    guard next < command.endIndex else { return nil }
                    current.append(command[next])
                    index = next
                } else if open == "\"", "$`".contains(character), current.isEmpty || current.hasPrefix("-") {
                    return nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == "\\" {
                let next = command.index(after: index)
                guard next < command.endIndex else { return nil }
                current.append(command[next])
                inWord = true
                index = next
            } else if character == " " || character == "\t" {
                if inWord {
                    words.append(Word(text: current, end: index))
                    current = ""
                    inWord = false
                }
            } else if isOperator(character) {
                // `#` only starts a comment at a word boundary; inside a word it is a letter.
                guard character == "#", inWord else { return nil }
                current.append(character)
            } else {
                current.append(character)
                inWord = true
            }
            index = command.index(after: index)
        }
        guard quote == nil else { return nil }
        if inWord {
            words.append(Word(text: current, end: command.endIndex))
        }
        return words
    }
}
