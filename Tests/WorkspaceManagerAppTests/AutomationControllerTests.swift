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
        // orderFront realizes and composites the window without activating the app (no focus
        // steal), mirroring the backgrounded-capture contract used for the native window
        // snapshot below. Off-screen placement keeps it invisible.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        // Let the page paint before capturing; takeSnapshot of a blank view is a valid but empty PNG.
        try? await Task.sleep(for: .milliseconds(800))

        let outcome = await WebSurfaceSnapshotCapture.capture(webView, maxWidth: 320, timeoutSeconds: 5)
        window.orderOut(nil)

        // WindowServer compositing is required for takeSnapshot; a headless CI host may not
        // provide it (WKErrorDomain 1), so a non-captured outcome is tolerated the same way as
        // the native window snapshot below — mechanism fidelity is proven by the evidence lane.
        guard case .captured(let pngData, let width, let height) = outcome else {
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

    @Test("Close reports a typed close request without claiming the tile closed")
    func closeRoutesThroughExistingClosePath() throws {
        let fixture = makeFixture()

        let result = try fixture.controller.automationCloseTile(for: fixture.primaryHandle)

        // Close is fire-and-forget and Ghostty may still prompt, so the result never claims the
        // change landed — only that the request entered the normal close-confirmation path.
        #expect(result.outcome == .requested)
        #expect(!result.changed)
        #expect(result.closedSurfaceID == fixture.primary.id.uuidString)
        #expect(fixture.closedSessionIDs == [fixture.primary.id])
    }

    @Test("Operator handle lists windows without owning a tile; tile handle is denied")
    func operatorWindowsProjection() throws {
        // A store with no live session at all — operator scope must not depend on a caller tile.
        let store = TileTreeStore()
        let registry = AutomationHandleRegistry()
        let operatorEntry = registry.registerOperator(appScopeID: "workspaces.local")
        let descriptor = AutomationWindowDescriptor(
            windowID: "7",
            title: "WorkSpaces",
            subtitle: nil,
            isMain: true,
            isKey: false,
            isVisible: true,
            x: 0,
            y: 0,
            width: 1200,
            height: 800
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            windows: { [descriptor] }
        )

        let result = try controller.automationWindows(for: operatorEntry.handle)
        #expect(result.windows == [descriptor])
        #expect(
            result.system.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .uiRead,
            ])
        #expect(controller.automationHandleIsOperator(operatorEntry.handle))
    }

    @Test("Windows route fails closed for tile, under-capable, and stale handles")
    func operatorWindowsFailClosed() throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "tile" })
        // A tile handle carrying the full v1 tile capabilities — but not window.read.
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
            windows: { [] }
        )

        // Tile handle: has tile capabilities but not window.read → capability_denied.
        do {
            _ = try controller.automationWindows(for: "tile")
            Issue.record("Expected a tile handle to be denied window.read")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
        #expect(!controller.automationHandleIsOperator("tile"))

        // Unknown/stale handle → stale_handle.
        do {
            _ = try controller.automationWindows(for: "not-live")
            Issue.record("Expected an unknown handle to be stale")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .staleHandle)
        }
    }

    @Test("Operator handle lists workspaces without owning a tile; tile handle is denied")
    func operatorWorkspacesProjection() throws {
        // A store with no live session at all — operator scope must not depend on a caller tile.
        let store = TileTreeStore()
        let registry = AutomationHandleRegistry()
        let operatorEntry = registry.registerOperator(appScopeID: "workspaces.local")
        let repoID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let inventory = AutomationWorkspaceInventory(
            repos: [
                AutomationRepoDescriptor(
                    repoID: repoID,
                    name: "workspaces",
                    path: "/Users/test/workspaces",
                    isSelected: true
                )
            ],
            workspaces: [
                AutomationWorkspaceDescriptor(
                    workspaceID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    repoID: repoID,
                    name: "feature-a",
                    path: "/Users/test/workspaces/feature-a",
                    branch: "feature-a",
                    status: "archived",
                    isArchived: true,
                    backend: "lume",
                    isSelected: false
                )
            ]
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            workspaceInventory: { inventory }
        )

        let result = try controller.automationWorkspaces(for: operatorEntry.handle)
        #expect(result.repos == inventory.repos)
        #expect(result.workspaces == inventory.workspaces)
        #expect(result.workspaces.first?.isArchived == true)
        #expect(result.workspaces.first?.backend == "lume")
        #expect(
            result.system.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .uiRead,
            ])
        #expect(controller.automationHandleIsOperator(operatorEntry.handle))
    }

    @Test("Workspaces route fails closed for tile, under-capable, and stale handles")
    func operatorWorkspacesFailClosed() throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "tile" })
        // A tile handle carrying the full v1 tile capabilities — but not workspace.read.
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
            workspaceInventory: { AutomationWorkspaceInventory() }
        )

        // Tile handle: has tile capabilities but not workspace.read → capability_denied.
        do {
            _ = try controller.automationWorkspaces(for: "tile")
            Issue.record("Expected a tile handle to be denied workspace.read")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
        #expect(!controller.automationHandleIsOperator("tile"))

        // Unknown/stale handle → stale_handle.
        do {
            _ = try controller.automationWorkspaces(for: "not-live")
            Issue.record("Expected an unknown handle to be stale")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .staleHandle)
        }
    }

    @Test("Operator handle snapshots a window via the provider; capabilities echo operator scope")
    func operatorWindowSnapshotReturnsCapture() async throws {
        let store = TileTreeStore()
        let registry = AutomationHandleRegistry()
        let operatorEntry = registry.registerOperator(appScopeID: "workspaces.local")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        var requestedWindowIDs: [String] = []
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            windowSnapshot: { windowID in
                requestedWindowIDs.append(windowID)
                return .captured(pngData: png, width: 2800, height: 1800)
            }
        )

        let result = try await controller.automationWindowSnapshot(for: operatorEntry.handle, windowID: "42")
        #expect(result.windowID == "42")
        #expect(result.width == 2800)
        #expect(result.height == 1800)
        #expect(Data(base64Encoded: result.data) == png)
        #expect(
            result.system.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .uiRead,
            ])
        #expect(requestedWindowIDs == ["42"])
    }

    @Test("Window snapshot denies a tile handle before invoking the capture provider")
    func operatorWindowSnapshotDeniesTileHandle() async throws {
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/Users/test/repo"),
                directory: URL(fileURLWithPath: "/Users/test/repo")
            ).session
        let registry = AutomationHandleRegistry(makeHandle: { "tile" })
        _ = registry.upsert(
            hostSessionID: primary.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "app",
            capabilities: AutomationAPI.v1Capabilities
        )
        var captureCalls = 0
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            windowSnapshot: { _ in
                captureCalls += 1
                return .captured(pngData: Data([0x89]), width: 1, height: 1)
            }
        )

        do {
            _ = try await controller.automationWindowSnapshot(for: "tile", windowID: "42")
            Issue.record("Expected a tile handle to be denied window.snapshot")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }
        // The capability gate runs before the capture provider, so nothing was captured.
        #expect(captureCalls == 0)
    }

    @Test("WindowSnapshotService rejects ids it does not own without capturing")
    func windowSnapshotServiceRejectsUnownedWindows() {
        // Deterministic, headless-safe: the own-window guard resolves against the supplied window
        // list, so a non-numeric, non-positive, or non-app-owned id is unknownWindow before any
        // WindowServer capture is attempted.
        #expect(WindowSnapshotService.snapshot(windowID: "not-a-number", windows: []) == .unknownWindow)
        #expect(WindowSnapshotService.snapshot(windowID: "0", windows: []) == .unknownWindow)
        #expect(WindowSnapshotService.snapshot(windowID: "999999999", windows: []) == .unknownWindow)
    }

    @Test("Live window capture produces a bounded, non-empty composited PNG")
    func liveWindowCaptureProducesPNG() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.systemBlue.cgColor
        window.contentView = content
        // orderFront realizes and composites the window without activating the app (no focus steal),
        // mirroring the backgrounded-capture contract. Off-screen placement keeps it invisible.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))

        let outcome = WindowSnapshotService.snapshot(windowID: String(window.windowNumber))
        window.orderOut(nil)

        // WindowServer compositing is required to capture; a headless CI host may not provide it, so
        // a non-capturable outcome is tolerated. When capture does succeed (local GUI session, the
        // evidence lane), assert the PNG is non-empty and dimensionally sane, and drop the evidence.
        switch outcome {
        case .captured(let pngData, let width, let height):
            #expect(!pngData.isEmpty)
            #expect(width >= 480)  // >= point size; Retina backing may 2x it
            #expect(height >= 320)
            #expect(pngData.count <= AutomationAPI.windowSnapshotMaxRawBytes)
            #expect(pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))  // PNG magic
            if let dir = ProcessInfo.processInfo.environment["WINDOW_SNAPSHOT_EVIDENCE_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("window-snapshot.png")
                try? pngData.write(to: url)
            }
        default:
            // No compositing available in this host — mechanism fidelity is proven by the evidence lane.
            break
        }
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
