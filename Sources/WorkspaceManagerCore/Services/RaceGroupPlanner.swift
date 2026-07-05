//
//  RaceGroupPlanner.swift
//  WorkspaceManagerCore
//
//  Pure planning for `workspaces ws race`: derives the group slug, the race-N
//  workspace names, and the shell-safe headless agent command. Kept free of
//  side effects so the CLI's fan-out stays a thin loop over a tested plan.
//

import Foundation

public struct RaceGroupPlan: Sendable, Equatable {
    public let slug: String
    public let workspaceNames: [String]
    public let agentCommand: String

    public init(slug: String, workspaceNames: [String], agentCommand: String) {
        self.slug = slug
        self.workspaceNames = workspaceNames
        self.agentCommand = agentCommand
    }
}

public enum RaceGroupPlanner {
    public static let countRange = 1...8
    public static let maxSlugLength = 40
    public static let fallbackSlug = "group"

    public static func plan(
        prompt: String,
        count: Int,
        command: String,
        nameOverride: String? = nil
    ) -> RaceGroupPlan {
        let clampedCount = min(max(count, countRange.lowerBound), countRange.upperBound)
        let slug = deriveSlug(prompt: prompt, nameOverride: nameOverride)
        let workspaceNames = (1...clampedCount).map { "race-\(slug)-\($0)" }
        let agentCommand = "\(command) -p \(shellQuoted(prompt))"
        return RaceGroupPlan(slug: slug, workspaceNames: workspaceNames, agentCommand: agentCommand)
    }

    /// Kebab-cases the override or the prompt's first four words. Stricter than
    /// `WorkspaceService.sanitizeWorkspaceNameComponent` because the result also feeds
    /// `git worktree add -b <name>`, so only letters, digits, and dashes survive.
    static func deriveSlug(prompt: String, nameOverride: String?) -> String {
        let trimmedOverride = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if let trimmedOverride, !trimmedOverride.isEmpty {
            source = trimmedOverride
        } else {
            source = prompt.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        }

        var parts: [String] = []
        var current = ""
        for character in source.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }

        var slug = parts.joined(separator: "-")
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength))
            while slug.hasSuffix("-") {
                slug = String(slug.dropLast())
            }
        }
        return slug.isEmpty ? fallbackSlug : slug
    }

    /// Single-quote shell quoting: safe against `$`, backticks, double quotes, and
    /// embedded single quotes (`'` becomes `'\''`).
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
