//
//  AutomationUIStateTests.swift
//  WorkspaceManagerTests
//
//  Covers the ui.read surface end to end without launching the app: the projection
//  rules (ordering, token vocabulary, pill text), the pure golden comparator, the
//  /v1/ui-state route, and the shipped per-scenario goldens under fixtures/ui-state/
//  against fixture-predicted snapshots — including the deliberate banner toggle that
//  must fail the diff.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

// MARK: - Fixture-predicted snapshots

/// The structural state a fixture-mode evidence-lane launch renders: `UIFixtureSeeder`'s
/// six repos with all workspaces active, a terminal attached, and — verified live against
/// the debug app on 2026-08-07 — no workspace selected. A `--clean-data` fixture launch has
/// no prior selection to restore and does not auto-select one, so `selection.kind` is `none`
/// and no sidebar row is selected. (The shipped goldens were regenerated from that live read
/// through `scripts/ui-state-golden.sh update`; this is the offline mirror of it.)
private func fixtureSnapshot(banners: [AutomationUIBanner]) -> AutomationUIStateSnapshot {
    func row(_ name: String) -> AutomationUIStateWorkspaceRow {
        AutomationUIStateWorkspaceRow(name: name, status: "active", isSelected: false, attention: nil)
    }
    return AutomationUIStateProjection.snapshot(
        selection: AutomationUIStateSelection(kind: .none, name: nil),
        banners: banners,
        attentionCount: 0,
        minimalToolbar: false,
        sidebar: [
            AutomationUIStateRepoSection(
                name: "bertram-chat",
                isSelected: false,
                workspaces: [row("feature-auth"), row("bugfix-422"), row("refactor-state")]
            ),
            AutomationUIStateRepoSection(
                name: "bread-builder", isSelected: false, workspaces: [row("refactor-runtime")]),
            AutomationUIStateRepoSection(name: "services", isSelected: false, workspaces: []),
            AutomationUIStateRepoSection(name: "skills", isSelected: false, workspaces: [row("skills-v13")]),
            AutomationUIStateRepoSection(name: "superpowers", isSelected: false, workspaces: []),
            AutomationUIStateRepoSection(name: "workspaces", isSelected: false, workspaces: []),
        ],
        terminal: AutomationUIStateTerminal(attached: true, tabCount: 1, splitCount: 0)
    )
}

private func goldenURL(scenario: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/WorkspaceManagerTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("fixtures/ui-state/\(scenario).json")
}

private func goldenDocument(scenario: String) throws -> UIStateGolden.Document {
    try UIStateGolden.document(from: Data(contentsOf: goldenURL(scenario: scenario)))
}

// MARK: - Projection rules

@Suite("AutomationUIStateProjection")
struct AutomationUIStateProjectionTests {
    @Test func statusTokenBucketsRunStatesByTone() {
        #expect(AutomationUIStateProjection.statusToken(for: .idle) == nil)
        #expect(AutomationUIStateProjection.statusToken(for: .complete) == nil)
        #expect(AutomationUIStateProjection.statusToken(for: .thinking) == "running")
        #expect(
            AutomationUIStateProjection.statusToken(for: .runningTool(name: "bash", detail: nil))
                == "running")
        #expect(
            AutomationUIStateProjection.statusToken(for: .awaitingInput(reason: .permissionPrompt))
                == "attention")
        #expect(
            AutomationUIStateProjection.statusToken(for: .errored(category: .unknown, message: nil))
                == "critical")
    }

    @Test func attentionPillTextMirrorsPillVisibility() {
        #expect(AutomationUIStateProjection.attentionPillText(count: 0, minimalToolbar: false) == nil)
        #expect(
            AutomationUIStateProjection.attentionPillText(count: 2, minimalToolbar: false)
                == "2 need you")
    }

    @Test func minimalToolbarHidesThePillAtAnyCount() {
        // The pill lives in the trailing toolbar group the minimalToolbar experiment removes,
        // so with the experiment on there is no rendered text for any count to produce.
        #expect(AutomationUIStateProjection.attentionPillText(count: 2, minimalToolbar: true) == nil)
        #expect(AutomationUIStateProjection.attentionPillText(count: 0, minimalToolbar: true) == nil)

        let snapshot = AutomationUIStateProjection.snapshot(
            selection: AutomationUIStateSelection(kind: .none, name: nil),
            banners: [],
            attentionCount: 4,
            minimalToolbar: true,
            sidebar: [],
            terminal: AutomationUIStateTerminal(attached: false, tabCount: 0, splitCount: 0)
        )
        #expect(snapshot.attentionPillText == nil)
    }

    @Test func snapshotAppliesOrderingContract() {
        let snapshot = AutomationUIStateProjection.snapshot(
            selection: AutomationUIStateSelection(kind: .none, name: nil),
            banners: [.restoreSessions, .modelStoreDegraded],
            attentionCount: 0,
            minimalToolbar: false,
            sidebar: [
                AutomationUIStateRepoSection(
                    name: "zeta",
                    isSelected: false,
                    workspaces: [
                        AutomationUIStateWorkspaceRow(
                            name: "b", status: "active", isSelected: false, attention: nil),
                        AutomationUIStateWorkspaceRow(
                            name: "a", status: "active", isSelected: false, attention: nil),
                    ]
                ),
                AutomationUIStateRepoSection(name: "alpha", isSelected: true, workspaces: []),
            ],
            terminal: AutomationUIStateTerminal(attached: false, tabCount: 0, splitCount: 0)
        )
        #expect(snapshot.banners == ["model_store_degraded", "restore_sessions"])
        #expect(snapshot.sidebar.map(\.name) == ["alpha", "zeta"])
        #expect(snapshot.sidebar[1].workspaces.map(\.name) == ["a", "b"])
    }
}

// MARK: - Golden comparator

@Suite("UIStateGolden comparator")
struct UIStateGoldenComparatorTests {
    private func document(ignore: [String] = [], state: String) throws -> UIStateGolden.Document {
        let json = """
            {"scenario": "test", "ignore": [\(ignore.map { "\"\($0)\"" }.joined(separator: ","))], "state": \(state)}
            """
        return try UIStateGolden.document(from: Data(json.utf8))
    }

    @Test func identicalTreesProduceNoMismatches() throws {
        let doc = try document(state: #"{"a": 1, "b": ["x"], "c": {"d": true}}"#)
        let actual = try UIStateGolden.jsonValue(from: Data(#"{"c": {"d": true}, "b": ["x"], "a": 1}"#.utf8))
        #expect(UIStateGolden.compare(document: doc, actualState: actual).isEmpty)
    }

    @Test func valueChangeReportsPathSortedMismatches() throws {
        let doc = try document(state: #"{"banners": ["restore_sessions"], "a": 1}"#)
        let actual = try UIStateGolden.jsonValue(from: Data(#"{"banners": [], "a": 2}"#.utf8))
        let mismatches = UIStateGolden.compare(document: doc, actualState: actual)
        #expect(mismatches.map(\.path) == ["state.a", "state.banners.count"])
    }

    @Test func missingAndExtraKeysAreBothReported() throws {
        let doc = try document(state: #"{"present": 1}"#)
        let actual = try UIStateGolden.jsonValue(from: Data(#"{"extra": 1}"#.utf8))
        let mismatches = UIStateGolden.compare(document: doc, actualState: actual)
        #expect(mismatches.count == 2)
        #expect(mismatches[0].path == "state.extra")
        #expect(mismatches[0].expected == nil)
        #expect(mismatches[1].path == "state.present")
        #expect(mismatches[1].actual == nil)
    }

    @Test func ignorePathsPruneBothSidesIncludingArrayElements() throws {
        let doc = try document(
            ignore: ["tabs.title"],
            state: #"{"tabs": [{"title": "golden", "isActive": true}]}"#
        )
        let actual = try UIStateGolden.jsonValue(
            from: Data(#"{"tabs": [{"title": "live-shell", "isActive": true}]}"#.utf8))
        #expect(UIStateGolden.compare(document: doc, actualState: actual).isEmpty)
    }

    @Test func boolAndNumberStayDistinct() throws {
        let doc = try document(state: #"{"flag": true}"#)
        let actual = try UIStateGolden.jsonValue(from: Data(#"{"flag": 1}"#.utf8))
        #expect(UIStateGolden.compare(document: doc, actualState: actual).count == 1)
    }
}

// MARK: - Shipped goldens vs fixture-predicted snapshots

@Suite("UI-state goldens")
struct UIStateGoldenFixtureTests {
    @Test(arguments: [
        ("clean", [AutomationUIBanner]()),
        ("orphan-banner", [AutomationUIBanner.workspaceOrphanCleanup]),
    ])
    func goldenMatchesFixturePrediction(scenario: String, banners: [AutomationUIBanner]) throws {
        let document = try goldenDocument(scenario: scenario)
        #expect(document.scenario == scenario)
        let actual = try UIStateGolden.jsonValue(encoding: fixtureSnapshot(banners: banners))
        let mismatches = UIStateGolden.compare(document: document, actualState: actual)
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test func deliberateBannerToggleFailsTheDiff() throws {
        // The acceptance probe: the orphan-banner golden against a state whose banner
        // is missing must fail, and fail at the banner path specifically.
        let document = try goldenDocument(scenario: "orphan-banner")
        let actual = try UIStateGolden.jsonValue(encoding: fixtureSnapshot(banners: []))
        let mismatches = UIStateGolden.compare(document: document, actualState: actual)
        #expect(!mismatches.isEmpty)
        #expect(mismatches.allSatisfy { $0.path.hasPrefix("state.banners") })
    }

    @Test(arguments: ["clean", "orphan-banner"])
    func goldenStateDecodesAsSnapshotSchema(scenario: String) throws {
        // Schema pin: a golden that drifts from AutomationUIStateSnapshot's Codable
        // shape fails here even if the generic tree comparison happens to pass.
        struct GoldenFile: Decodable {
            let scenario: String
            let state: AutomationUIStateSnapshot
        }
        let data = try Data(contentsOf: goldenURL(scenario: scenario))
        let decoded = try JSONDecoder().decode(GoldenFile.self, from: data)
        #expect(decoded.scenario == scenario)
    }
}

// MARK: - /v1/ui-state route

@MainActor
private final class UIStateFakeController: AutomationControlling {
    var uiStateCalls: [String] = []

    static let result = AutomationUIStateResult(
        state: AutomationUIStateProjection.snapshot(
            selection: AutomationUIStateSelection(kind: .workspace, name: "feature-auth"),
            banners: [.workspaceOrphanCleanup],
            attentionCount: 1,
            minimalToolbar: false,
            sidebar: [],
            terminal: AutomationUIStateTerminal(attached: true, tabCount: 1, splitCount: 0)
        ),
        volatile: AutomationUIStateVolatile(
            selectedWorkspaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            selectedRepoID: nil,
            tabTitles: ["zsh"]
        )
    )

    func automationUIState(for handle: String) throws -> AutomationUIStateResult {
        guard handle == "operator" else {
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include ui.read.")
        }
        uiStateCalls.append(handle)
        return Self.result
    }

    func automationContext(for handle: String) throws -> AutomationContextResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWindows(for handle: String) throws -> AutomationWindowsResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationSelectWorkspace(
        for handle: String, workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationCreateWorkspace(
        for handle: String, request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationArchiveWorkspace(
        for handle: String, request: AutomationWorkspaceArchiveRequest
    ) async throws -> AutomationWorkspaceArchiveResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationOpenRepoTerminal(
        for handle: String,
        request: AutomationRepoTerminalRequest
    ) async throws -> AutomationRepoTerminalResult {
        throw AutomationServiceError(.staleHandle, "stale")
    }

    func automationSetWorkspaceNote(
        for handle: String, request: AutomationWorkspaceNoteRequest
    ) async throws -> AutomationWorkspaceNoteResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWindowSnapshot(
        for handle: String, windowID: String
    ) async throws -> AutomationWindowSnapshotResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationReadSurface(
        for handle: String, request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWebSurfaceSnapshot(
        for handle: String, sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationFocusTile(
        for handle: String, direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationSplitTile(
        for handle: String, direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationCloseTile(for handle: String) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWriteInput(
        for handle: String, text: String, submit: Bool
    ) throws -> AutomationInputWriteResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationHandleIsOperator(_ handle: String) -> Bool { handle == "operator" }
}

/// A conformer that relies on the protocol's defaulted `automationUIState` — stands in
/// for pre-existing fakes that predate the route and must keep compiling and fail closed.
@MainActor
private final class UIStateDefaultedController: AutomationControlling {
    func automationContext(for handle: String) throws -> AutomationContextResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWindows(for handle: String) throws -> AutomationWindowsResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationSelectWorkspace(
        for handle: String, workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationCreateWorkspace(
        for handle: String, request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationArchiveWorkspace(
        for handle: String, request: AutomationWorkspaceArchiveRequest
    ) async throws -> AutomationWorkspaceArchiveResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationOpenRepoTerminal(
        for handle: String,
        request: AutomationRepoTerminalRequest
    ) async throws -> AutomationRepoTerminalResult {
        throw AutomationServiceError(.staleHandle, "stale")
    }

    func automationSetWorkspaceNote(
        for handle: String, request: AutomationWorkspaceNoteRequest
    ) async throws -> AutomationWorkspaceNoteResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWindowSnapshot(
        for handle: String, windowID: String
    ) async throws -> AutomationWindowSnapshotResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationReadSurface(
        for handle: String, request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWebSurfaceSnapshot(
        for handle: String, sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationFocusTile(
        for handle: String, direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationSplitTile(
        for handle: String, direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationCloseTile(for handle: String) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationWriteInput(
        for handle: String, text: String, submit: Bool
    ) throws -> AutomationInputWriteResult {
        throw AutomationServiceError(.unsupported, "not under test")
    }
    func automationHandleIsOperator(_ handle: String) -> Bool { false }
}

@Suite("GET /v1/ui-state route")
struct AutomationUIStateRouteTests {
    private func request(method: String = "GET", handle: String? = "operator") -> HTTPRequest {
        var headers: [String: String] = [:]
        if let handle {
            headers[AutomationAPI.handleHeader] = handle
        }
        return HTTPRequest(method: method, path: "/v1/ui-state", headers: headers, body: Data())
    }

    @Test func getReturnsTheControllersResult() async throws {
        let controller = await UIStateFakeController()
        let result = await AutomationHTTPRouter.route(
            request(), controller: controller, enabled: true)
        #expect(result.status == 200)
        let envelope = try JSONDecoder().decode(
            AutomationResponseEnvelope<AutomationUIStateResult>.self, from: result.body)
        #expect(envelope.ok)
        #expect(envelope.result == UIStateFakeController.result)
        #expect(envelope.result?.state.banners == ["workspace_orphan_cleanup"])
        #expect(envelope.result?.volatile.tabTitles == ["zsh"])
    }

    @Test func nonGetIsMethodNotAllowed() async throws {
        let controller = await UIStateFakeController()
        let result = await AutomationHTTPRouter.route(
            request(method: "POST"), controller: controller, enabled: true)
        #expect(result.status == 405)
    }

    @Test func underCapableHandleFailsClosed() async throws {
        let controller = await UIStateFakeController()
        let result = await AutomationHTTPRouter.route(
            request(handle: "tile"), controller: controller, enabled: true)
        #expect(result.status == 403)
    }

    @Test func defaultedConformerFailsClosedAsUnsupported() async throws {
        let controller = await UIStateDefaultedController()
        let result = await AutomationHTTPRouter.route(
            request(), controller: controller, enabled: true)
        #expect(result.status == 409)
        let envelope = try JSONDecoder().decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: result.body)
        #expect(envelope.error?.code == .unsupported)
    }
}
