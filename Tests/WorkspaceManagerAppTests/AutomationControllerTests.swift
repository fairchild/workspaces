import AppKit
import Foundation
import Testing
import WebKit

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
        let store = TileTreeStore()
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
            tileTreeStore: store,
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

    @Test("Web surface handles are rejected as unsupported")
    func webSurfaceHandleIsRejected() throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "web-handle" })
        // Even with a live host session and full capabilities, a non-terminal surface kind gates
        // the request before the liveness check (which would misreport it as a stale handle).
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .web,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: AutomationAPI.v1Capabilities
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        do {
            _ = try controller.automationContext(for: "web-handle")
            Issue.record("Expected web-surface handle to be rejected as unsupported")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .unsupported)
        }
    }

    @Test("Web surface list returns provided descriptors for a browser.read handle")
    func webSurfaceListReturnsDescriptors() throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "browser" })
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: AutomationAPI.v1Capabilities
        )
        let descriptor = AutomationWebSurfaceDescriptor(
            sourceID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            scope: .global,
            ownerID: nil,
            displayName: "Docs",
            configuredURL: "https://example.test",
            liveURL: nil,
            title: nil,
            isLive: false,
            isLoading: nil
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            webSurfaces: { [descriptor] }
        )

        let result = try controller.automationWebSurfaces(for: "browser")
        #expect(result.webSurfaces == [descriptor])
        #expect(result.system.capabilities.contains(.browserRead))
    }

    @Test("Web surface list denies handles without browser.read")
    func webSurfaceListDeniesWithoutBrowserRead() throws {
        let store = TileTreeStore()
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
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            webSurfaces: {
                [
                    AutomationWebSurfaceDescriptor(
                        sourceID: UUID(),
                        scope: .global,
                        ownerID: nil,
                        displayName: "Docs",
                        configuredURL: "https://example.test",
                        liveURL: nil,
                        title: nil,
                        isLive: false,
                        isLoading: nil
                    )
                ]
            }
        )

        do {
            _ = try controller.automationWebSurfaces(for: "limited")
            Issue.record("Expected browser.read to be required for web-surface listing")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
    }

    @Test("Web-surface snapshot returns the provider's captured PNG for a browser.read handle")
    func webSurfaceSnapshotReturnsCapture() async throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "browser" })
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: AutomationAPI.v1Capabilities
        )
        let sourceID = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            webSnapshot: { requested in
                requested == sourceID ? .captured(pngData: png, width: 8, height: 4) : .unknownSource
            }
        )

        let result = try await controller.automationWebSurfaceSnapshot(for: "browser", sourceID: sourceID)
        #expect(result.sourceID == sourceID)
        #expect(result.width == 8)
        #expect(result.byteCount == png.count)
        #expect(Data(base64Encoded: result.data) == png)
        #expect(result.system.capabilities.contains(.browserRead))
    }

    @Test("Web-surface snapshot maps a not-live source to unsupported")
    func webSurfaceSnapshotNotLive() async throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "browser" })
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: AutomationAPI.v1Capabilities
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            webSnapshot: { _ in .notLive }
        )

        do {
            _ = try await controller.automationWebSurfaceSnapshot(for: "browser", sourceID: UUID())
            Issue.record("Expected a not-live source to fail as unsupported")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .unsupported)
        }
    }

    @Test("Web-surface snapshot denies handles without browser.read before capturing")
    func webSurfaceSnapshotDeniesWithoutBrowserRead() async throws {
        let store = TileTreeStore()
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
        var captureCalls = 0
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            webSnapshot: { _ in
                captureCalls += 1
                return .notLive
            }
        )

        do {
            _ = try await controller.automationWebSurfaceSnapshot(for: "limited", sourceID: UUID())
            Issue.record("Expected browser.read to be required for snapshotting")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
        // The capability gate runs before the capture provider, so no snapshot was attempted.
        #expect(captureCalls == 0)
    }

    @Test("Live WKWebView capture produces a bounded, non-empty PNG")
    func liveWebViewCaptureProducesPNG() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(webView)
        webView.loadHTMLString(
            "<html><body style=\"margin:0;background:#2266cc;\"><h1 style=\"color:white\">snapshot</h1></body></html>",
            baseURL: nil
        )
        // Let the page paint before capturing; takeSnapshot of a blank view is a valid but empty PNG.
        try? await Task.sleep(for: .milliseconds(800))

        let outcome = await WebSurfaceSnapshotCapture.capture(webView, maxWidth: 320, timeoutSeconds: 5)
        guard case .captured(let pngData, let width, let height) = outcome else {
            Issue.record("Expected a captured PNG, got \(outcome)")
            return
        }
        #expect(!pngData.isEmpty)
        #expect(width > 0)
        #expect(height > 0)
        // Bounded: scaled to at most maxWidth (backing-store scale may 2x on Retina).
        #expect(width <= 320 * 2)
        #expect(pngData.count <= AutomationAPI.webSnapshotMaxRawBytes)

        if let dir = ProcessInfo.processInfo.environment["WEB_SNAPSHOT_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("web-surface-snapshot.png")
            try? pngData.write(to: url)
        }
    }

    @Test("Input write requires the input.write capability")
    func inputWriteRequiresCapability() throws {
        let fixture = makeFixture()

        do {
            _ = try fixture.controller.automationWriteInput(
                for: fixture.primaryHandle,
                text: "echo hi",
                submit: false
            )
            Issue.record("Expected default v1 handle to lack input.write")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
    }

    @Test("Input write fails closed when the experiment is disabled after grant")
    func inputWriteFailsClosedWhenExperimentDisabled() throws {
        let harness = makeInputWriteHarness(isInputWriteEnabled: false)

        do {
            _ = try harness.controller.automationWriteInput(for: "granted", text: "echo hi", submit: false)
            Issue.record("Expected disabled experiment to deny granted handle")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
    }

    @Test("Input write without a live surface view reports stale handle")
    func inputWriteWithoutLiveSurfaceIsStale() throws {
        let harness = makeInputWriteHarness(isInputWriteEnabled: true)

        do {
            _ = try harness.controller.automationWriteInput(for: "granted", text: "echo hi", submit: true)
            Issue.record("Expected missing surface view to read as stale")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .staleHandle)
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
        let store: TileTreeStore
        let controller: AutomationController
        let primary: HostTerminalSession
        let primaryHandle: String
        var focusedSessionIDs: [UUID] = []
        var closedSessionIDs: [UUID] = []

        init() {
            store = TileTreeStore()
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
                tileTreeStore: store,
                focusTerminal: { _ in },
                requestCloseTerminal: { _ in }
            )
            controller.update(
                tileTreeStore: store,
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

    private struct InputWriteHarness {
        let store: TileTreeStore
        let controller: AutomationController
    }

    /// Builds a controller whose "granted" handle carries `input.write`, with the experiment
    /// gate injected so tests exercise both sides without touching global defaults.
    private func makeInputWriteHarness(isInputWriteEnabled: Bool) -> InputWriteHarness {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "granted" })
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: AutomationAPI.inputWriteCapabilities
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            isInputWriteEnabled: { isInputWriteEnabled }
        )
        return InputWriteHarness(store: store, controller: controller)
    }
}
