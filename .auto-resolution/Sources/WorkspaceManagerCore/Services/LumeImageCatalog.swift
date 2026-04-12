//
//  LumeImageCatalog.swift
//  WorkspaceManagerCore
//
//  Catalog and resolution helpers for prepared Lume VM images.
//

import Foundation

public enum LumeImageMatchKind: String, Sendable, Equatable {
    case exact
    case nearestSameFamily
}

public struct LumeImageCatalogEntry: Sendable, Equatable {
    public let guestOS: WorkspaceGuestOS
    public let macOSFamily: LumeMacOSFamily
    public let xcodeVersion: String?
    public let imageReference: String
    public let registry: String
    public let organization: String
    public let displayLabel: String
    public let supportTier: String

    public init(
        guestOS: WorkspaceGuestOS,
        macOSFamily: LumeMacOSFamily,
        xcodeVersion: String?,
        imageReference: String,
        registry: String,
        organization: String,
        displayLabel: String,
        supportTier: String = "stable"
    ) {
        self.guestOS = guestOS
        self.macOSFamily = macOSFamily
        self.xcodeVersion = xcodeVersion
        self.imageReference = imageReference
        self.registry = registry
        self.organization = organization
        self.displayLabel = displayLabel
        self.supportTier = supportTier
    }
}

public struct LumeImageResolution: Sendable, Equatable {
    public let hostProfile: LumeHostProfile
    public let entry: LumeImageCatalogEntry
    public let matchKind: LumeImageMatchKind

    public init(
        hostProfile: LumeHostProfile,
        entry: LumeImageCatalogEntry,
        matchKind: LumeImageMatchKind
    ) {
        self.hostProfile = hostProfile
        self.entry = entry
        self.matchKind = matchKind
    }

    public var profileKey: String {
        hostProfile.profileKey
    }

    public var profileDisplayName: String {
        entry.displayLabel
    }
}

public struct LumeImageCatalog: Sendable {
    public static let `default` = LumeImageCatalog()

    public static let defaultEntries: [LumeImageCatalogEntry] = [
        LumeImageCatalogEntry(
            guestOS: .macOS,
            macOSFamily: .tahoe,
            xcodeVersion: "26.2",
            imageReference: "macos-tahoe-xcode:26.2",
            registry: "ghcr.io",
            organization: "workspacemanager",
            displayLabel: "macOS Tahoe 26.2 + Xcode 26.2"
        ),
        LumeImageCatalogEntry(
            guestOS: .macOS,
            macOSFamily: .tahoe,
            xcodeVersion: "26.0",
            imageReference: "macos-tahoe-xcode:26.0",
            registry: "ghcr.io",
            organization: "workspacemanager",
            displayLabel: "macOS Tahoe 26.0 + Xcode 26.0"
        ),
        LumeImageCatalogEntry(
            guestOS: .macOS,
            macOSFamily: .sequoia,
            xcodeVersion: "16.4",
            imageReference: "macos-sequoia-xcode:16.4",
            registry: "ghcr.io",
            organization: "workspacemanager",
            displayLabel: "macOS Sequoia 15 + Xcode 16.4"
        ),
    ]

    public let entries: [LumeImageCatalogEntry]

    public init(entries: [LumeImageCatalogEntry] = Self.defaultEntries) {
        self.entries = entries
    }

    public func resolveDefaultMacOSImage(for hostProfile: LumeHostProfile) throws -> LumeImageResolution {
        let sameFamilyEntries = entries.filter {
            $0.guestOS == .macOS && $0.macOSFamily == hostProfile.macOSFamily
        }

        guard !sameFamilyEntries.isEmpty else {
            throw LumeRuntimeError.imageUnavailable(
                "No macOS VM image is available yet for \(hostProfile.macOSFamily.label). Choose Linux VM instead."
            )
        }

        if let xcodeVersion = hostProfile.xcodeVersion,
            let exactEntry = sameFamilyEntries.first(where: { $0.xcodeVersion == xcodeVersion })
        {
            return LumeImageResolution(
                hostProfile: hostProfile,
                entry: exactEntry,
                matchKind: .exact
            )
        }

        return LumeImageResolution(
            hostProfile: hostProfile,
            entry: selectNearestSameFamilyEntry(
                candidates: sameFamilyEntries,
                hostXcodeVersion: hostProfile.xcodeVersion
            ),
            matchKind: .nearestSameFamily
        )
    }

    private func selectNearestSameFamilyEntry(
        candidates: [LumeImageCatalogEntry],
        hostXcodeVersion: String?
    ) -> LumeImageCatalogEntry {
        guard let hostVersion = hostXcodeVersion.flatMap(VersionNumber.init) else {
            return
                candidates
                .sorted { lhs, rhs in
                    (VersionNumber(lhs.xcodeVersion) ?? .zero) > (VersionNumber(rhs.xcodeVersion) ?? .zero)
                }
                .first ?? candidates[0]
        }

        return candidates.min { lhs, rhs in
            versionDistance(
                from: VersionNumber(lhs.xcodeVersion),
                to: hostVersion
            )
                < versionDistance(
                    from: VersionNumber(rhs.xcodeVersion),
                    to: hostVersion
                )
        } ?? candidates[0]
    }

    private func versionDistance(
        from candidate: VersionNumber?,
        to host: VersionNumber
    ) -> Int {
        guard let candidate else { return Int.max }
        let lhs = candidate.normalizedSegments(count: 3)
        let rhs = host.normalizedSegments(count: 3)
        return abs(lhs[0] - rhs[0]) * 10_000
            + abs(lhs[1] - rhs[1]) * 100
            + abs(lhs[2] - rhs[2])
    }
}

public struct VersionNumber: Sendable, Equatable, Comparable {
    public static let zero = VersionNumber(segments: [0, 0, 0])

    public let segments: [Int]

    public init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let segments =
            cleaned
            .split(separator: ".")
            .compactMap { Int($0) }
        guard !segments.isEmpty else { return nil }
        self.segments = segments
    }

    private init(segments: [Int]) {
        self.segments = segments
    }

    public func normalizedSegments(count: Int) -> [Int] {
        if segments.count >= count {
            return Array(segments.prefix(count))
        }
        return segments + Array(repeating: 0, count: count - segments.count)
    }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let lhsSegments = lhs.normalizedSegments(count: max(lhs.segments.count, rhs.segments.count))
        let rhsSegments = rhs.normalizedSegments(count: max(lhs.segments.count, rhs.segments.count))
        for index in lhsSegments.indices {
            if lhsSegments[index] != rhsSegments[index] {
                return lhsSegments[index] < rhsSegments[index]
            }
        }
        return false
    }
}
