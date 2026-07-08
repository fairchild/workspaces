//
//  WorkspacesAppIntents.swift
//  WorkspaceManager
//
//  Shortcuts/Siri/Spotlight actions for the workspace automation verbs. These intents are a veneer:
//  they resolve App Intents entities, then call the same AutomationController methods used by the
//  local socket routes so the gesture-verb layer remains the only mutation semantics path.
//

import AppIntents
import Foundation
import WorkspaceManagerCore

@MainActor
struct WorkspacesAppIntentAutomationClient: Sendable {
    enum CreateOutcome: Equatable {
        case completed(AutomationWorkspaceCreateResult)
        case confirmationRequired(AutomationConfirmationRequirement)
    }

    typealias ControllerProvider =
        @MainActor @Sendable () throws -> (
            controller: any AutomationControlling, handle: String
        )

    static let live = WorkspacesAppIntentAutomationClient {
        try AutomationIntegrationLifecycle.shared.appIntentControllerAndHandle()
    }

    private let controllerProvider: ControllerProvider

    init(controllerProvider: @escaping ControllerProvider) {
        self.controllerProvider = controllerProvider
    }

    func inventory() throws -> AutomationWorkspaceInventory {
        do {
            let (controller, handle) = try controllerAndHandle()
            let result = try controller.automationWorkspaces(for: handle)
            return AutomationWorkspaceInventory(repos: result.repos, workspaces: result.workspaces)
        } catch let error as WorkspacesAppIntentError {
            throw error
        } catch let error as AutomationServiceError {
            throw WorkspacesAppIntentError.automation(error.response)
        }
    }

    func select(workspaceID: String) async throws -> AutomationWorkspaceSelectResult {
        do {
            let (controller, handle) = try controllerAndHandle()
            return try await controller.automationSelectWorkspace(for: handle, workspaceID: workspaceID)
        } catch let error as WorkspacesAppIntentError {
            throw error
        } catch let error as AutomationServiceError {
            throw WorkspacesAppIntentError.automation(error.response)
        }
    }

    func create(
        repoID: String,
        name: String,
        providerID: String?,
        guestOS: WorkspaceGuestOS?
    ) async throws -> CreateOutcome {
        do {
            let (controller, handle) = try controllerAndHandle()
            let result = try await controller.automationCreateWorkspace(
                for: handle,
                request: AutomationWorkspaceCreateRequest(
                    repoID: repoID,
                    name: name,
                    providerID: providerID,
                    guestOS: guestOS
                )
            )
            if let confirmation = result.confirmation, result.outcome == .confirmationRequired {
                return .confirmationRequired(confirmation)
            }
            return .completed(result)
        } catch let error as WorkspacesAppIntentError {
            throw error
        } catch let error as AutomationServiceError {
            throw WorkspacesAppIntentError.automation(error.response)
        }
    }

    private func controllerAndHandle() throws -> (
        controller: any AutomationControlling, handle: String
    ) {
        do {
            return try controllerProvider()
        } catch let error as AutomationServiceError {
            throw WorkspacesAppIntentError.automation(error.response)
        }
    }
}

enum WorkspacesAppIntentError: LocalizedError, Equatable {
    case automation(AutomationErrorResponse)
    case confirmationRequired(String)
    case cancelled(String)

    var errorDescription: String? {
        switch self {
        case .automation(let response):
            return response.message
        case .confirmationRequired(let message):
            return message
        case .cancelled(let message):
            return message
        }
    }
}

struct WorkspaceIntentEntity: AppEntity, Equatable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace"
    static let defaultQuery = WorkspaceIntentWorkspaceQuery()

    let id: String
    let repoID: String?
    let repoName: String?
    let name: String
    let path: String
    let branch: String?
    let status: String
    let isSelected: Bool

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [repoName, branch, isSelected ? "selected" : status]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(
        id: String,
        repoID: String?,
        repoName: String?,
        name: String,
        path: String,
        branch: String?,
        status: String,
        isSelected: Bool
    ) {
        self.id = id
        self.repoID = repoID
        self.repoName = repoName
        self.name = name
        self.path = path
        self.branch = branch
        self.status = status
        self.isSelected = isSelected
    }

    init(descriptor: AutomationWorkspaceDescriptor, repoNameByID: [UUID: String]) {
        self.init(
            id: descriptor.workspaceID.uuidString,
            repoID: descriptor.repoID?.uuidString,
            repoName: descriptor.repoID.flatMap { repoNameByID[$0] },
            name: descriptor.name,
            path: descriptor.path,
            branch: descriptor.branch,
            status: descriptor.status,
            isSelected: descriptor.isSelected
        )
    }
}

struct WorkspaceIntentRepoEntity: AppEntity, Equatable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repository"
    static let defaultQuery = WorkspaceIntentRepoQuery()

    let id: String
    let name: String
    let path: String
    let isSelected: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(isSelected ? "selected - " : "")\(path)"
        )
    }

    init(id: String, name: String, path: String, isSelected: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.isSelected = isSelected
    }

    init(descriptor: AutomationRepoDescriptor) {
        self.init(
            id: descriptor.repoID.uuidString,
            name: descriptor.name,
            path: descriptor.path,
            isSelected: descriptor.isSelected
        )
    }
}

struct WorkspaceIntentWorkspaceQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [WorkspaceIntentEntity.ID]) async throws -> [WorkspaceIntentEntity] {
        let wanted = Set(identifiers)
        return try await allEntities().filter { wanted.contains($0.id) }
    }

    func allEntities() async throws -> [WorkspaceIntentEntity] {
        let inventory = try await Self.inventory()
        let repoNameByID = Dictionary(uniqueKeysWithValues: inventory.repos.map { ($0.repoID, $0.name) })
        return inventory.workspaces.map {
            WorkspaceIntentEntity(descriptor: $0, repoNameByID: repoNameByID)
        }
    }

    func entities(matching string: String) async throws -> [WorkspaceIntentEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return try await allEntities() }
        return try await allEntities().filter { entity in
            [entity.name, entity.repoName, entity.branch, entity.path]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    private static func inventory() async throws -> AutomationWorkspaceInventory {
        try await MainActor.run {
            try WorkspacesAppIntentAutomationClient.live.inventory()
        }
    }
}

struct WorkspaceIntentRepoQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [WorkspaceIntentRepoEntity.ID]) async throws -> [WorkspaceIntentRepoEntity] {
        let wanted = Set(identifiers)
        return try await allEntities().filter { wanted.contains($0.id) }
    }

    func allEntities() async throws -> [WorkspaceIntentRepoEntity] {
        let inventory = try await Self.inventory()
        return inventory.repos.map(WorkspaceIntentRepoEntity.init(descriptor:))
    }

    func entities(matching string: String) async throws -> [WorkspaceIntentRepoEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return try await allEntities() }
        return try await allEntities().filter { entity in
            [entity.name, entity.path]
                .map { $0.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    private static func inventory() async throws -> AutomationWorkspaceInventory {
        try await MainActor.run {
            try WorkspacesAppIntentAutomationClient.live.inventory()
        }
    }
}

enum WorkspaceIntentGuestOS: String, AppEnum {
    case linux
    case macOS = "macos"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Guest OS"
    static let caseDisplayRepresentations: [WorkspaceIntentGuestOS: DisplayRepresentation] = [
        .linux: "Linux",
        .macOS: "macOS",
    ]

    var workspaceGuestOS: WorkspaceGuestOS {
        switch self {
        case .linux:
            return .linux
        case .macOS:
            return .macOS
        }
    }
}

struct ListWorkspacesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Workspaces"
    static let description = IntentDescription(
        "Lists the WorkSpaces repositories and workspaces visible to automation.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ReturnsValue<[WorkspaceIntentEntity]> & ProvidesDialog {
        let workspaces = try await WorkspaceIntentWorkspaceQuery().allEntities()
        return .result(
            value: workspaces,
            dialog: "Found \(workspaces.count) workspace\(workspaces.count == 1 ? "" : "s")."
        )
    }
}

struct SelectWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Workspace"
    static let description = IntentDescription(
        "Selects a WorkSpaces workspace by driving the same gesture as the sidebar.")
    static let openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: WorkspaceIntentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Select \(\.$workspace)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let result = try await WorkspacesAppIntentAutomationClient.live.select(workspaceID: workspace.id)
            if result.outcome == .confirmationRequired {
                let confirmed = try await $workspace.requestConfirmation(
                    for: workspace,
                    dialog: "\(result.message ?? "WorkSpaces needs confirmation before selecting this workspace.")"
                )
                guard confirmed else {
                    throw WorkspacesAppIntentError.cancelled("Workspace selection was cancelled.")
                }
            }
            return .result(dialog: "Selected \(workspace.name).")
        } catch let error as AutomationServiceError {
            throw WorkspacesAppIntentError.automation(error.response)
        }
    }
}

struct CreateWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Workspace"
    static let description = IntentDescription(
        "Creates a workspace through the same WorkSpaces gesture path as the app UI.")
    static let openAppWhenRun = true

    @Parameter(title: "Repository")
    var repo: WorkspaceIntentRepoEntity

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Provider")
    var providerID: String?

    @Parameter(title: "Guest OS")
    var guestOS: WorkspaceIntentGuestOS?

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$name) in \(\.$repo)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let outcome = try await WorkspacesAppIntentAutomationClient.live.create(
                repoID: repo.id,
                name: name,
                providerID: providerID,
                guestOS: guestOS?.workspaceGuestOS
            )
            switch outcome {
            case .completed(let result):
                return .result(dialog: "Created \(result.workspaceName).")
            case .confirmationRequired(let confirmation):
                let confirmed = try await $repo.requestConfirmation(
                    for: repo,
                    dialog: IntentDialog(
                        full: "\(confirmation.title)",
                        supporting: "\(confirmation.message)"
                    )
                )
                guard confirmed else {
                    throw WorkspacesAppIntentError.cancelled("Workspace creation was cancelled.")
                }
                return .result(dialog: "\(confirmation.message)")
            }
        } catch let error as AutomationServiceError {
            throw WorkspacesAppIntentError.automation(error.response)
        }
    }
}

struct WorkspacesAppShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListWorkspacesIntent(),
            phrases: [
                "List workspaces in \(.applicationName)",
                "Show my \(.applicationName) workspaces",
            ],
            shortTitle: "List Workspaces",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: SelectWorkspaceIntent(),
            phrases: [
                "Select workspace in \(.applicationName)",
                "Switch \(.applicationName) workspace",
            ],
            shortTitle: "Select Workspace",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: CreateWorkspaceIntent(),
            phrases: [
                "Create workspace in \(.applicationName)",
                "New \(.applicationName) workspace",
            ],
            shortTitle: "Create Workspace",
            systemImageName: "plus.rectangle"
        )
    }
}
