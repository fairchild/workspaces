import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationController")
struct AutomationControllerTests {
    @Test("Context resolves caller from opaque handle")
    func contextResolvesCaller() throws {
        let fixture = makeFixture()
        let context = try fixture.controller.automationContext(for: fixture.primaryHandle)

        #expect(context.surface.hostSessionID == fixture.primary.id)
        #expect(context.surface.kind == .terminal)
        #expect(context.surface.isCaller)
        #expect(context.surface.tileID != nil)
        #expect(context.scope.primaryHostSessionID == fixture.primary.id)
        #expect(context.system.capabilities.contains(.contextRead))
    }

    @Test("Missing or stale handles fail closed")
    func staleHandlesFailClosed() throws {
        let fixture = makeFixture()
        #expect(throws: AutomationServiceError.self) {
            _ = try fixture.controller.automationContext(for: "not-live")
        }

        _ = fixture.store.handleProcessExit(for: fixture.primary.id)
        do {
            _ = try fixture.controller.automationContext(for: fixture.primaryHandle)
            Issue.record("Expected stale handle after process exit")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .staleHandle)
        }
    }

    @Test("Surfaces list stays inside caller scope")
    func surfacesStayInsideCallerScope() throws {
        let fixture = makeFixture()
        let sibling = try #require(fixture.store.createTab())
        _ = fixture.store.activateSession(
            key: .repoPath("/Users/test/other"),
            directory: URL(fileURLWithPath: "/Users/test/other")
        )
        _ = fixture.store.splitFocusedTile(inTabContaining: fixture.primary.id)

        let surfaces = try fixture.controller.automationSurfaces(for: fixture.primaryHandle).surfaces
        let hostIDs = Set(surfaces.compactMap(\.hostSessionID))

        #expect(hostIDs.contains(fixture.primary.id))
        #expect(hostIDs.contains(sibling.id))
        #expect(hostIDs.count == 3)
        #expect(!hostIDs.contains(fixture.store.activeSessionID ?? UUID()))
    }

    @Test("Directional focus reports no neighbor without mutation")
    func directionalFocusNoNeighbor() throws {
        let fixture = makeFixture()

        let result = try fixture.controller.automationFocusTile(for: fixture.primaryHandle, direction: .right)

        #expect(result.changed == false)
        #expect(result.reason == "no_neighbor")
        #expect(fixture.focusedSessionIDs.isEmpty)
    }

    @Test("Directional and relative focus target the paired split tile")
    func focusTargetsSplitTile() throws {
        let fixture = makeFixture()
        let split = try #require(fixture.store.splitFocusedTile(inTabContaining: fixture.primary.id))
        let splitHandle = try #require(fixture.store.automationEnvironment(for: split)?.handle)

        let right = try fixture.controller.automationFocusTile(for: fixture.primaryHandle, direction: .right)
        let previous = try fixture.controller.automationFocusTile(for: splitHandle, direction: .previous)

        #expect(right.changed)
        #expect(right.focusedSurfaceID == split.id.uuidString)
        #expect(previous.changed)
        #expect(previous.focusedSurfaceID == fixture.primary.id.uuidString)
        #expect(fixture.focusedSessionIDs == [split.id, fixture.primary.id])
    }

    @Test("Split creates a new pane through host terminal state")
    func splitUsesHostTerminalState() async throws {
        let fixture = makeFixture()

        let result = try fixture.controller.automationSplitTile(for: fixture.primaryHandle, direction: .down)
        let split = try #require(fixture.store.splitSession(for: fixture.primary.id))

        #expect(result.changed)
        #expect(result.createdSurfaceID == split.id.uuidString)
        #expect(fixture.store.splitLayout(for: fixture.primary.id)?.axis == .topBottom)

        try await Task.sleep(for: .milliseconds(180))
        #expect(fixture.focusedSessionIDs == [split.id])
    }

    @Test("Split grows an existing split tree from the primary tile")
    func splitExistingTreeCreatesNewSurface() throws {
        let fixture = makeFixture()
        let firstSplit = try #require(fixture.store.splitFocusedTile(inTabContaining: fixture.primary.id))

        let secondSplit = try fixture.controller.automationSplitTile(for: fixture.primaryHandle, direction: .down)
        let secondSurfaceIDString = try #require(secondSplit.createdSurfaceID)
        let secondSurfaceID = try #require(UUID(uuidString: secondSurfaceIDString))
        let surfaces = try fixture.controller.automationSurfaces(for: fixture.primaryHandle).surfaces
        let hostIDs = Set(surfaces.compactMap(\.hostSessionID))

        #expect(secondSplit.changed)
        #expect(secondSplit.createdSurfaceID != firstSplit.id.uuidString)
        #expect(fixture.store.paneCount(forPrimarySessionID: fixture.primary.id) == 3)
        #expect(hostIDs.contains(firstSplit.id))
        #expect(hostIDs.contains(secondSurfaceID))
    }

    @Test("Split from secondary tile is rejected until arbitrary tile splitting lands")
    func splitFromSecondaryTileIsUnsupported() throws {
        let fixture = makeFixture()
        let split = try #require(fixture.store.splitFocusedTile(inTabContaining: fixture.primary.id))
        let splitHandle = try #require(fixture.store.automationEnvironment(for: split)?.handle)

        do {
            _ = try fixture.controller.automationSplitTile(for: splitHandle, direction: .right)
            Issue.record("Expected secondary split tile request to be unsupported")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .unsupported)
        }
    }

    @Test("Limited handles cannot use capabilities they were not granted")
    func limitedHandleCapabilitiesAreEnforced() throws {
        let store = HostTerminalStateStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "limited" })
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: [.contextRead]
        )
        let controller = AutomationController(
            handleRegistry: registry,
            hostTerminalState: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        _ = try controller.automationContext(for: "limited")
        do {
            _ = try controller.automationSplitTile(for: "limited", direction: .right)
            Issue.record("Expected tile.split to require tile.split capability")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
    }

    @Test("Close routes through existing close request path")
    func closeRoutesThroughExistingClosePath() throws {
        let fixture = makeFixture()

        let result = try fixture.controller.automationCloseTile(for: fixture.primaryHandle)

        #expect(result.changed)
        #expect(result.closedSurfaceID == fixture.primary.id.uuidString)
        #expect(fixture.closedSessionIDs == [fixture.primary.id])
    }

    @MainActor
    private final class Fixture {
        let store: HostTerminalStateStore
        let controller: AutomationController
        let primary: HostTerminalSession
        let primaryHandle: String
        var focusedSessionIDs: [UUID] = []
        var closedSessionIDs: [UUID] = []

        init() {
            store = HostTerminalStateStore()
            let handleRegistry = AutomationHandleRegistry()
            store.configureAutomation(
                handleRegistry: handleRegistry,
                socketPath: "/tmp/workspaces-automation.sock"
            )
            primary =
                store.activateSession(
                    key: .repoPath("/Users/test/repo"),
                    directory: URL(fileURLWithPath: "/Users/test/repo")
                ).session
            primaryHandle = store.automationEnvironment(for: primary)?.handle ?? ""
            controller = AutomationController(
                handleRegistry: handleRegistry,
                hostTerminalState: store,
                focusTerminal: { _ in },
                requestCloseTerminal: { _ in }
            )
            controller.update(
                hostTerminalState: store,
                focusTerminal: { [weak self] sessionID in
                    self?.focusedSessionIDs.append(sessionID)
                },
                requestCloseTerminal: { [weak self] sessionID in
                    self?.closedSessionIDs.append(sessionID)
                }
            )
        }
    }

    private func makeFixture() -> Fixture {
        Fixture()
    }
}
