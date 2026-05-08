//
//  AgentOSCRouter.swift
//  WorkspaceManager
//
//  Channel 3 entry point: routes libghostty OSC notifications and BEL into the
//  AgentSessionRegistry. Sits between GhosttyRuntimeActionBridge (raw C action
//  tags) and the registry (typed AgentEvents) so the bridge never imports
//  WorkspaceManagerCore directly.
//
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 3.
//

import AppKit
import Foundation
import WorkspaceManagerCore

/// Singleton glue between the libghostty action callback and the registry. The
/// app wires it up at startup with a registry, an adapter registry, and a
/// resolver from `GhosttySurfaceView` to the host session id.
@MainActor
final class AgentOSCRouter {
    static let shared = AgentOSCRouter()

    private weak var registry: AgentSessionRegistry?
    private var adapters: AgentAdapterRegistry = AgentAdapterRegistry()
    private var resolveHostSession: (@MainActor (GhosttySurfaceView) -> UUID?)?

    private init() {}

    /// Wire the router with the live registry and the surface→session resolver.
    /// Safe to call repeatedly; each call replaces the prior wiring.
    func attach(
        registry: AgentSessionRegistry,
        adapters: AgentAdapterRegistry = AgentAdapterRegistry(),
        resolveHostSession: @escaping @MainActor (GhosttySurfaceView) -> UUID?
    ) {
        self.registry = registry
        self.adapters = adapters
        self.resolveHostSession = resolveHostSession
    }

    /// Detach all references. Used in tests and on app teardown.
    func detach() {
        self.registry = nil
        self.resolveHostSession = nil
    }

    /// Forward an OSC 9 / OSC 777 desktop notification. `surfaceAddress` is the
    /// raw libghostty surface pointer used as a stable correlation id for logs.
    func handleDesktopNotification(
        title: String?,
        body: String,
        surfaceView: GhosttySurfaceView,
        surfaceAddress: UInt
    ) {
        guard let hostID = resolveHostSession?(surfaceView) else { return }
        guard let registry else { return }
        let kind = registry.statuses[hostID]?.kind ?? .unknown
        let adapter = adapters.adapter(for: kind)
        let event = adapter.mapOSCNotification(title: title, body: body)
        registry.ingest(
            event,
            for: hostID,
            origin: .osc(surfaceID: UInt64(surfaceAddress))
        )
    }

    /// Forward a BEL ring. The Claude adapter currently maps this to `.bell`,
    /// which the registry treats as a no-op for v1; we still route it so future
    /// surfaces (audio cue, badge animation) can observe.
    func handleRingBell(
        surfaceView: GhosttySurfaceView,
        surfaceAddress: UInt
    ) {
        guard let hostID = resolveHostSession?(surfaceView) else { return }
        guard let registry else { return }
        let kind = registry.statuses[hostID]?.kind ?? .unknown
        let adapter = adapters.adapter(for: kind)
        let event = adapter.mapBell()
        registry.ingest(
            event,
            for: hostID,
            origin: .bell
        )
    }
}
