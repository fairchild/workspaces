//
//  RemoteBackendRegistry.swift
//  WorkspaceManagerCore
//
//  Registry for resolving remote backends by persisted identifier.
//

import Foundation

public final class RemoteBackendRegistry: RemoteBackendRegistryProtocol, @unchecked Sendable {
    public static let shared = RemoteBackendRegistry(
        backends: [
            DaytonaBackend.shared,
            SSHBackend.shared,
        ],
        creationBackendIdentifiers: [
            DaytonaBackend.identifier,
            SSHBackend.identifier,
        ]
    )

    private let backendsByIdentifier: [String: any RemoteBackendProtocol]
    public let creationBackendIdentifiers: [String]

    public init(
        backends: [any RemoteBackendProtocol],
        creationBackendIdentifiers: [String]? = nil
    ) {
        self.backendsByIdentifier = Dictionary(uniqueKeysWithValues: backends.map { ($0.identifier, $0) })
        self.creationBackendIdentifiers = creationBackendIdentifiers ?? backends.map(\.identifier)
    }

    public func backend(for identifier: String) -> (any RemoteBackendProtocol)? {
        backendsByIdentifier[identifier]
    }
}
