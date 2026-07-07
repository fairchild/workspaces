//
//  WebSurfaceEnumerator.swift
//  WorkspaceManager
//
//  Maps WorkSpaces web sources plus their live WKWebView state into the
//  Automation API's read-only `AutomationWebSurfaceDescriptor` list. Pure and
//  dependency-injected — records and live state are supplied by the caller — so
//  the fail-closed rule (no live view → nil live fields, never a fabricated URL
//  or title) is unit-testable without SwiftData or a WKWebView.
//

import Foundation
import WorkspaceManagerCore

/// Static, model-independent view of one WorkSpaces web source.
struct WebSurfaceRecord: Sendable, Equatable {
    let sourceID: UUID
    let displayName: String
    let configuredURL: String
    let scope: AutomationWebSurfaceScope
    let ownerID: UUID?
}

/// Live signal read from an instantiated web surface's `WKWebView`. Absent when
/// no surface is currently backing the source.
struct WebSurfaceLiveState: Sendable, Equatable {
    let url: String?
    let title: String?
    let isLoading: Bool
}

extension WebSurfaceRecord {
    init(from source: WebSource) {
        let scope: AutomationWebSurfaceScope
        let ownerID: UUID?
        switch source.ownershipScope {
        case .global:
            scope = .global
            ownerID = nil
        case .repo(let id):
            scope = .repo
            ownerID = id
        case .workspace(let id):
            scope = .workspace
            ownerID = id
        }
        self.init(
            sourceID: source.id,
            displayName: source.name,
            configuredURL: source.baseURLString,
            scope: scope,
            ownerID: ownerID
        )
    }
}

enum WebSurfaceEnumerator {
    /// Produces one descriptor per record, ordered as given. `liveState` returns the
    /// live WKWebView signal for a source id, or `nil` when no surface is live — in
    /// which case the descriptor reports `isLive == false` with nil live fields.
    static func descriptors(
        records: [WebSurfaceRecord],
        liveState: (UUID) -> WebSurfaceLiveState?
    ) -> [AutomationWebSurfaceDescriptor] {
        records.map { record in
            let live = liveState(record.sourceID)
            return AutomationWebSurfaceDescriptor(
                sourceID: record.sourceID,
                scope: record.scope,
                ownerID: record.ownerID,
                displayName: record.displayName,
                configuredURL: record.configuredURL,
                liveURL: live?.url,
                title: live?.title,
                isLive: live != nil,
                isLoading: live.map(\.isLoading)
            )
        }
    }
}
