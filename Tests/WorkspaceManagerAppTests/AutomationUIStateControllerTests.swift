//
//  AutomationUIStateControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Exercises the real AutomationController.automationUIState against a real handle registry
//  and the real AutomationUIStateEnumerator over SwiftData models: operator-scope capability
//  enforcement, the window-bound `unsupported` condition (never installed, cleared by an
//  update, dropped on window teardown), and the chrome the enumerator actually projects.
//  The route-level suite in WorkspaceManagerTests uses a fake controller; this one is the
//  controller and enumerator themselves.
//

import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("AutomationController ui.read")
struct AutomationUIStateControllerTests {
    private struct Graph {
        let repos: [Repo]
        let selectedWorkspace: Workspace
        let attentionWorkspace: Workspace
    }

    /// Two repos with three workspaces between them, deliberately inserted out of name
    /// order so the projection's sorting contract is observable rather than incidental.
    /// One window installs the layer these suites drive; a teardown names it, so an
    /// overlapping window's teardown cannot clear it (#1375).
    private static let windowOwner = UUID()

    private func makeGraph() throws -> Graph {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let zeta = Repo(name: "zeta", localPath: URL(fileURLWithPath: "/tmp/zeta"))
        let alpha = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        context.insert(zeta)
        context.insert(alpha)

        func workspace(_ name: String, in repo: Repo, status: WorkspaceStatus = .active) -> Workspace {
            let workspace = Workspace(
                name: name,
                path: URL(fileURLWithPath: "/tmp/workspaces/\(name)"),
                sourceRepo: repo,
                status: status
            )
            context.insert(workspace)
            return workspace
        }

        let bugfix = workspace("bugfix", in: alpha)
        let apiRefactor = workspace("api-refactor", in: alpha)
        _ = workspace("stopped-thing", in: zeta, status: .stopped)

        return Graph(
            repos: [zeta, alpha],
            selectedWorkspace: apiRefactor,
            attentionWorkspace: bugfix
        )
    }

    private func makeController(
        uiState: (@MainActor () -> AutomationUIStateCapture)?
    ) -> (controller: AutomationController, operatorHandle: String, store: TileTreeStore) {
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let store = TileTreeStore()
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            windowBoundOwner: Self.windowOwner,
            uiState: uiState
        )
        return (controller, entry.handle, store)
    }

    private func expectFailure(_ code: AutomationErrorCode, _ body: () throws -> some Any) {
        do {
            _ = try body()
            Issue.record("Expected \(code.rawValue) but the call succeeded.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == code)
        } catch {
            Issue.record("Expected AutomationServiceError but got \(error).")
        }
    }

    @Test("operator handle reads the chrome the enumerator projects, with ui.read in scope")
    func operatorReadsProjectedChrome() throws {
        let graph = try makeGraph()
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/tmp/alpha"),
                directory: URL(fileURLWithPath: "/tmp/alpha")
            ).session
        let statuses: [UUID: AgentSessionStatus] = [
            graph.attentionWorkspace.id: AgentSessionStatus(
                hostSessionID: primary.id,
                cwd: "/tmp/workspaces/bugfix",
                run: .awaitingInput(reason: .permissionPrompt)
            )
        ]

        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            uiState: {
                AutomationUIStateEnumerator.capture(
                    repos: graph.repos,
                    selectedWorkspaceID: graph.selectedWorkspace.id,
                    selectedRepoID: nil,
                    workspaceStatuses: statuses,
                    attentionCount: 1,
                    minimalToolbar: false,
                    banners: [.workspaceOrphanCleanup],
                    tileTreeStore: store
                )
            }
        )

        let result = try controller.automationUIState(for: entry.handle)

        #expect(result.system.capabilities.contains(.uiRead))
        #expect(result.state.selection.kind == .workspace)
        #expect(result.state.selection.name == "api-refactor")
        #expect(result.state.banners == ["workspace_orphan_cleanup"])
        #expect(result.state.attentionPillText == "1 need you")
        // Sorting contract: repos and rows come back name-sorted, not insertion-ordered.
        #expect(result.state.sidebar.map(\.name) == ["alpha", "zeta"])
        #expect(result.state.sidebar[0].workspaces.map(\.name) == ["api-refactor", "bugfix"])
        #expect(result.state.sidebar[0].workspaces[0].isSelected)
        #expect(result.state.sidebar[0].workspaces[1].attention == "attention")
        #expect(result.state.sidebar[1].workspaces.map(\.status) == ["stopped"])
        #expect(result.state.terminal.attached)
        #expect(result.state.terminal.tabCount == 1)
        #expect(result.volatile.selectedWorkspaceID == graph.selectedWorkspace.id)
    }

    @Test("the minimalToolbar experiment hides the pill in the projection too")
    func minimalToolbarSuppressesThePillText() throws {
        let graph = try makeGraph()
        let store = TileTreeStore()
        func capture(minimalToolbar: Bool) -> AutomationUIStateCapture {
            AutomationUIStateEnumerator.capture(
                repos: graph.repos,
                selectedWorkspaceID: graph.selectedWorkspace.id,
                selectedRepoID: nil,
                workspaceStatuses: [:],
                attentionCount: 3,
                minimalToolbar: minimalToolbar,
                banners: [],
                tileTreeStore: store
            )
        }

        // Same non-zero count, opposite experiment state: the pill text follows the toolbar
        // group's presence, not the count alone.
        #expect(capture(minimalToolbar: false).state.attentionPillText == "3 need you")
        #expect(capture(minimalToolbar: true).state.attentionPillText == nil)
    }

    @Test("no window has installed a reader, so ui.read is unsupported")
    func withoutAReaderIsUnsupported() {
        let (controller, handle, _) = makeController(uiState: nil)

        expectFailure(.unsupported) { try controller.automationUIState(for: handle) }
    }

    @Test("a tile handle lacks ui.read and is denied")
    func tileHandleDenied() {
        let registry = AutomationHandleRegistry(makeHandle: { "tile" })
        let store = TileTreeStore()
        let primary =
            store.activateSession(
                key: .repoPath("/tmp/alpha"),
                directory: URL(fileURLWithPath: "/tmp/alpha")
            ).session
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
            uiState: { .init(state: Self.emptySnapshot, volatile: Self.emptyVolatile) }
        )

        expectFailure(.capabilityDenied) { try controller.automationUIState(for: "tile") }
    }

    @Test("window teardown drops the reader rather than describing a window that is gone")
    func teardownClearsTheReader() throws {
        let (controller, handle, _) = makeController(
            uiState: { .init(state: Self.emptySnapshot, volatile: Self.emptyVolatile) })
        _ = try controller.automationUIState(for: handle)

        controller.detachGestureVerbs(owner: Self.windowOwner)

        expectFailure(.unsupported) { try controller.automationUIState(for: handle) }
    }

    @Test("an update that installs no reader clears the previous window's closure")
    func updateWithoutAReaderClearsIt() throws {
        let (controller, handle, store) = makeController(
            uiState: { .init(state: Self.emptySnapshot, volatile: Self.emptyVolatile) })
        _ = try controller.automationUIState(for: handle)

        controller.update(
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        expectFailure(.unsupported) { try controller.automationUIState(for: handle) }
    }

    private static let emptySnapshot = AutomationUIStateProjection.snapshot(
        selection: AutomationUIStateSelection(kind: .none, name: nil),
        banners: [],
        attentionCount: 0,
        minimalToolbar: false,
        sidebar: [],
        terminal: AutomationUIStateTerminal(attached: false, tabCount: 0, splitCount: 0)
    )

    private static let emptyVolatile = AutomationUIStateVolatile(
        selectedWorkspaceID: nil, selectedRepoID: nil, tabTitles: [])
}
