import Foundation
import WorkspaceManagerCore

enum WorkspaceNameSource: String, Sendable {
    case generatedDefault
    case manual
}

struct WorkspaceNameReservation: Sendable {
    let repoID: UUID
    let resolvedName: String
    let sanitizedName: String
}

enum WorkspaceNameGenerator {
    private static let adjectives = [
        "amber",
        "brisk",
        "clever",
        "dapper",
        "ember",
        "fabled",
        "gentle",
        "hollow",
        "jazzy",
        "lively",
        "mellow",
        "nimble",
        "opal",
        "peppy",
        "quiet",
        "rapid",
        "solar",
        "tidal",
        "velvet",
        "witty",
        "zesty",
    ]

    private static let nouns = [
        "badger",
        "comet",
        "falcon",
        "fjord",
        "fox",
        "harbor",
        "kite",
        "lynx",
        "meadow",
        "nova",
        "otter",
        "panda",
        "quartz",
        "rocket",
        "sparrow",
        "thistle",
        "trail",
        "voyager",
        "whale",
        "willow",
        "zeppelin",
    ]

    static func generateDefaultName(occupiedSanitizedNames: Set<String>) -> String {
        let combinationCount = adjectives.count * nouns.count
        guard combinationCount > 0 else {
            return nextAvailableVariant(
                for: "workspace",
                occupiedSanitizedNames: occupiedSanitizedNames
            )
        }

        let startIndex = Int.random(in: 0..<combinationCount)
        for offset in 0..<combinationCount {
            let candidate = baseName(at: (startIndex + offset) % combinationCount)
            let sanitizedCandidate = sanitizedName(candidate)
            if !occupiedSanitizedNames.contains(sanitizedCandidate) {
                return candidate
            }
        }

        return nextAvailableVariant(
            for: baseName(at: startIndex),
            occupiedSanitizedNames: occupiedSanitizedNames
        )
    }

    static func resolveName(
        _ requestedName: String,
        source: WorkspaceNameSource,
        occupiedSanitizedNames: Set<String>
    ) throws -> String {
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedRequestedName = sanitizedName(trimmedName)

        guard WorkspaceService.isValidWorkspaceNameComponent(sanitizedRequestedName) else {
            throw WorkspaceError.invalidName(name: requestedName)
        }

        guard occupiedSanitizedNames.contains(sanitizedRequestedName) else {
            return source == .manual ? trimmedName : sanitizedRequestedName
        }

        switch source {
        case .generatedDefault:
            return nextAvailableVariant(
                for: sanitizedRequestedName,
                occupiedSanitizedNames: occupiedSanitizedNames
            )
        case .manual:
            throw WorkspaceError.alreadyExists(name: sanitizedRequestedName)
        }
    }

    static func sanitizedNameSet<S: Sequence>(from names: S) -> Set<String> where S.Element == String {
        Set(
            names.compactMap { name in
                let sanitized = sanitizedName(name)
                return WorkspaceService.isValidWorkspaceNameComponent(sanitized) ? sanitized : nil
            }
        )
    }

    static func sanitizedName(_ name: String) -> String {
        WorkspaceService.sanitizeWorkspaceNameComponent(name)
    }

    private static func nextAvailableVariant(
        for baseName: String,
        occupiedSanitizedNames: Set<String>
    ) -> String {
        let sanitizedBaseName = sanitizedName(baseName)
        guard occupiedSanitizedNames.contains(sanitizedBaseName) else {
            return sanitizedBaseName
        }

        var suffix = 2
        var candidate = "\(sanitizedBaseName)-\(suffix)"
        while occupiedSanitizedNames.contains(candidate) {
            suffix += 1
            candidate = "\(sanitizedBaseName)-\(suffix)"
        }

        return candidate
    }

    private static func baseName(at index: Int) -> String {
        let adjective = adjectives[index / nouns.count]
        let noun = nouns[index % nouns.count]
        return "\(adjective)-\(noun)"
    }
}

actor WorkspaceNameReservationStore {
    static let shared = WorkspaceNameReservationStore()

    private var reservedSanitizedNamesByRepoID: [UUID: Set<String>] = [:]

    func reserveName(
        repoID: UUID,
        requestedName: String,
        source: WorkspaceNameSource,
        occupiedSanitizedNames: Set<String>
    ) throws -> WorkspaceNameReservation {
        let reservedNames = reservedSanitizedNamesByRepoID[repoID] ?? []
        let resolvedName = try WorkspaceNameGenerator.resolveName(
            requestedName,
            source: source,
            occupiedSanitizedNames: occupiedSanitizedNames.union(reservedNames)
        )
        let sanitizedResolvedName = WorkspaceNameGenerator.sanitizedName(resolvedName)
        var updatedReservedNames = reservedNames
        updatedReservedNames.insert(sanitizedResolvedName)
        reservedSanitizedNamesByRepoID[repoID] = updatedReservedNames

        return WorkspaceNameReservation(
            repoID: repoID,
            resolvedName: resolvedName,
            sanitizedName: sanitizedResolvedName
        )
    }

    func release(_ reservation: WorkspaceNameReservation) {
        guard var reservedNames = reservedSanitizedNamesByRepoID[reservation.repoID] else {
            return
        }

        reservedNames.remove(reservation.sanitizedName)
        if reservedNames.isEmpty {
            reservedSanitizedNamesByRepoID.removeValue(forKey: reservation.repoID)
        } else {
            reservedSanitizedNamesByRepoID[reservation.repoID] = reservedNames
        }
    }
}
