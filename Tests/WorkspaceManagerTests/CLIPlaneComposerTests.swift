import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLIPlaneComposer")
struct CLIPlaneComposerTests {
    private static let repoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
    private static let otherRepoID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
    private static let wsID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") ?? UUID()
    private static let archivedID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB") ?? UUID()

    private func makeInventory(
        repos: [AutomationRepoDescriptor]? = nil,
        workspaces: [AutomationWorkspaceDescriptor]? = nil
    ) -> AutomationWorkspaceInventory {
        AutomationWorkspaceInventory(
            repos: repos ?? [
                AutomationRepoDescriptor(
                    repoID: Self.repoID, name: "demo", path: "/repos/demo", isSelected: true)
            ],
            workspaces: workspaces ?? [
                AutomationWorkspaceDescriptor(
                    workspaceID: Self.wsID,
                    repoID: Self.repoID,
                    name: "feature",
                    path: "/ws/feature",
                    branch: "feature-branch",
                    status: "ready",
                    isArchived: false,
                    backend: "local",
                    isSelected: true
                ),
                AutomationWorkspaceDescriptor(
                    workspaceID: Self.archivedID,
                    repoID: Self.repoID,
                    name: "old",
                    path: "/ws/old",
                    branch: nil,
                    status: "archived",
                    isArchived: true,
                    backend: "local",
                    isSelected: false
                ),
            ]
        )
    }

    // MARK: Workspace list

    @Test("Without an app, workspace list keeps the legacy bare format")
    func workspaceListApplessFormat() {
        let rows = [CLIPlaneComposer.LocalRow(displayName: "demo/feature", path: "/ws/feature")]
        #expect(
            CLIPlaneComposer.workspaceListLines(app: nil, local: rows)
                == ["demo/feature\t/ws/feature"])
        #expect(
            CLIPlaneComposer.workspaceListLines(app: nil, local: [])
                == ["No workspaces tracked."])
    }

    @Test("With an app, workspace list derives from the app and labels CLI-local-only rows")
    func workspaceListTwoPlanes() {
        let local = [
            CLIPlaneComposer.LocalRow(displayName: "demo/feature", path: "/ws/feature"),
            CLIPlaneComposer.LocalRow(displayName: "demo/cli-only", path: "/ws/cli-only"),
        ]
        let lines = CLIPlaneComposer.workspaceListLines(app: makeInventory(), local: local)
        #expect(
            lines == [
                "Workspaces (running app):",
                "* demo/feature\t/ws/feature\tfeature-branch",
                "",
                "CLI-local only (not visible to the app):",
                "  demo/cli-only\t/ws/cli-only",
            ]
        )
    }

    @Test("Archived app workspaces stay out of the listing")
    func workspaceListExcludesArchived() {
        let lines = CLIPlaneComposer.workspaceListLines(app: makeInventory(), local: [])
        #expect(!lines.contains(where: { $0.contains("/ws/old") }))
    }

    @Test("With an app that has no active workspaces, the section says none")
    func workspaceListEmptyApp() {
        let inventory = makeInventory(workspaces: [])
        let lines = CLIPlaneComposer.workspaceListLines(app: inventory, local: [])
        #expect(lines == ["Workspaces (running app):", "  (none)"])
    }

    // MARK: Repo list

    @Test("Without an app, repo list keeps the legacy bare format")
    func repoListApplessFormat() {
        let rows = [CLIPlaneComposer.LocalRow(displayName: "demo", path: "/repos/demo")]
        #expect(CLIPlaneComposer.repoListLines(app: nil, local: rows) == ["demo\t/repos/demo"])
        #expect(CLIPlaneComposer.repoListLines(app: nil, local: []) == ["No repositories tracked."])
    }

    @Test("With an app, repo list carries the repo id and labels CLI-local-only rows")
    func repoListTwoPlanes() {
        let local = [CLIPlaneComposer.LocalRow(displayName: "elsewhere", path: "/repos/elsewhere")]
        let lines = CLIPlaneComposer.repoListLines(app: makeInventory(), local: local)
        #expect(
            lines == [
                "Repos (running app):",
                "* demo\t/repos/demo\t\(Self.repoID.uuidString)",
                "",
                "CLI-local only (not visible to the app):",
                "  elsewhere\t/repos/elsewhere",
            ]
        )
    }

    // MARK: Notices and guidance

    @Test("repo add produces a plane notice only when the app does not track the path")
    func repoAddNotice() {
        let inventory = makeInventory()
        #expect(CLIPlaneComposer.repoAddNotice(app: inventory, addedRepoPath: "/repos/demo") == nil)
        let notice = CLIPlaneComposer.repoAddNotice(app: inventory, addedRepoPath: "/repos/other")
        #expect(notice?.contains("CLI-local (appless) plane only") == true)
        #expect(notice?.contains("workspaces /repos/other") == true)
    }

    @Test("A repo the app tracks but the CLI does not yields cross-plane guidance")
    func missingLocalRepoGuidance() {
        let inventory = makeInventory()
        let byName = CLIPlaneComposer.missingLocalRepoGuidance(
            token: "demo", normalizedTokenPath: nil, app: inventory)
        #expect(byName?.contains("workspaces automation workspace create \(Self.repoID.uuidString) <name>") == true)
        #expect(byName?.contains("workspaces repo add /repos/demo") == true)

        let byPath = CLIPlaneComposer.missingLocalRepoGuidance(
            token: "~/repos/demo", normalizedTokenPath: "/repos/demo", app: inventory)
        #expect(byPath != nil)

        let miss = CLIPlaneComposer.missingLocalRepoGuidance(
            token: "unknown", normalizedTokenPath: "/nope", app: inventory)
        #expect(miss == nil)
    }

    // MARK: Workspace matching

    @Test("Selectors resolve against the app inventory: UUID, repo/name, unique name")
    func matchWorkspaceSelectors() {
        let inventory = makeInventory()
        let expected = CLIPlaneComposer.AppWorkspaceMatch(
            workspaceID: Self.wsID,
            name: "feature",
            repoName: "demo",
            repoPath: "/repos/demo",
            path: "/ws/feature",
            branch: "feature-branch"
        )
        #expect(
            CLIPlaneComposer.matchWorkspace(token: Self.wsID.uuidString, in: inventory)
                == .match(expected))
        #expect(CLIPlaneComposer.matchWorkspace(token: "demo/feature", in: inventory) == .match(expected))
        #expect(CLIPlaneComposer.matchWorkspace(token: "feature", in: inventory) == .match(expected))
        #expect(CLIPlaneComposer.matchWorkspace(token: "missing", in: inventory) == .none)
    }

    @Test("Archived workspaces never match")
    func matchWorkspaceExcludesArchived() {
        let inventory = makeInventory()
        #expect(CLIPlaneComposer.matchWorkspace(token: "old", in: inventory) == .none)
        #expect(CLIPlaneComposer.matchWorkspace(token: Self.archivedID.uuidString, in: inventory) == .none)
    }

    @Test("A bare name shared across repos is ambiguous, with candidates named")
    func matchWorkspaceAmbiguity() {
        let inventory = makeInventory(
            repos: [
                AutomationRepoDescriptor(
                    repoID: Self.repoID, name: "demo", path: "/repos/demo", isSelected: false),
                AutomationRepoDescriptor(
                    repoID: Self.otherRepoID, name: "other", path: "/repos/other", isSelected: false),
            ],
            workspaces: [
                AutomationWorkspaceDescriptor(
                    workspaceID: UUID(),
                    repoID: Self.repoID,
                    name: "feature",
                    path: "/ws/a",
                    branch: nil,
                    status: "ready",
                    isArchived: false,
                    backend: "local",
                    isSelected: false
                ),
                AutomationWorkspaceDescriptor(
                    workspaceID: UUID(),
                    repoID: Self.otherRepoID,
                    name: "feature",
                    path: "/ws/b",
                    branch: nil,
                    status: "ready",
                    isArchived: false,
                    backend: "local",
                    isSelected: false
                ),
            ]
        )
        #expect(
            CLIPlaneComposer.matchWorkspace(token: "feature", in: inventory)
                == .ambiguous(["demo/feature", "other/feature"]))
        #expect(
            CLIPlaneComposer.matchWorkspace(token: "demo/feature", in: inventory) != .none)
    }

    @Test("A workspace without a resolvable repo displays and matches by bare name")
    func matchWorkspaceWithoutRepo() {
        let inventory = makeInventory(
            repos: [],
            workspaces: [
                AutomationWorkspaceDescriptor(
                    workspaceID: Self.wsID,
                    repoID: nil,
                    name: "loose",
                    path: "/ws/loose",
                    branch: nil,
                    status: "ready",
                    isArchived: false,
                    backend: "local",
                    isSelected: false
                )
            ]
        )
        let outcome = CLIPlaneComposer.matchWorkspace(token: "loose", in: inventory)
        guard case .match(let match) = outcome else {
            Issue.record("expected a match, got \(outcome)")
            return
        }
        #expect(match.repoName == nil)
        #expect(match.path == "/ws/loose")
    }
}
