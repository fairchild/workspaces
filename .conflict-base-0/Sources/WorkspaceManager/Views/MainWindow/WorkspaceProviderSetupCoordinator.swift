//
//  WorkspaceProviderSetupCoordinator.swift
//  WorkspaceManager
//
//  Generic provider-owned setup orchestration for workspace actions.
//

import Foundation
import WorkspaceManagerCore

struct WorkspaceProviderSetupConfirmationRequest: Identifiable, Equatable {
    let id = UUID()
    let action: WorkspaceProviderSetupAction
    let confirmation: WorkspaceProviderSetupConfirmation

    var providerID: String { confirmation.providerID }
    var providerDisplayName: String { confirmation.providerDisplayName }
    var state: String? { confirmation.state }
    var title: String { confirmation.title }
    var primaryButtonTitle: String { confirmation.primaryButtonTitle }
    var introductoryText: [String] { confirmation.introductoryText }
    var learnMoreLabel: String? { confirmation.learnMoreLabel }
    var learnMoreURL: URL? { confirmation.learnMoreURL }
    var explanatoryStepsTitle: String { confirmation.explanatoryStepsTitle }
    var explanatorySteps: [String] { confirmation.explanatorySteps }
    var supplementaryText: String? { confirmation.supplementaryText }
    var footerText: String { confirmation.footerText }
}

struct WorkspaceProviderSetupProgressPresentation: Identifiable, Equatable {
    let id = UUID()
    let providerID: String
    let providerDisplayName: String
    let action: WorkspaceProviderSetupAction
    let title: String
    let bodyText: String
    var step: WorkspaceProviderSetupProgress
}

@MainActor
final class WorkspaceProviderSetupCoordinator: ObservableObject {
    @Published var confirmationRequest: WorkspaceProviderSetupConfirmationRequest?
    @Published var progressPresentation: WorkspaceProviderSetupProgressPresentation?
    @Published var errorMessage: String?

    private var pendingProvider: (any WorkspaceProviderSetupCapable)?
    private var pendingAction: WorkspaceProviderSetupAction?
    private var pendingResume: (@MainActor () async -> Void)?

    func prepareIfNeeded(
        provider: any WorkspaceProviderProtocol,
        action: WorkspaceProviderSetupAction,
        resume: @escaping @MainActor () async -> Void
    ) async throws -> Bool {
        guard let setupProvider = provider as? any WorkspaceProviderSetupCapable else {
            return false
        }

        guard let requirement = try await setupProvider.setupRequirement(for: action) else {
            return false
        }

        switch requirement {
        case .confirmation(let confirmation):
            pendingProvider = setupProvider
            pendingAction = action
            pendingResume = resume
            confirmationRequest = WorkspaceProviderSetupConfirmationRequest(
                action: action,
                confirmation: confirmation
            )
            return true
        case .alreadyInProgress:
            return true
        }
    }

    func cancelPendingAction() {
        confirmationRequest = nil
        progressPresentation = nil
        pendingProvider = nil
        pendingAction = nil
        pendingResume = nil
    }

    func confirmAndContinue() {
        guard
            let provider = pendingProvider,
            let action = pendingAction,
            let request = confirmationRequest
        else {
            return
        }

        confirmationRequest = nil
        progressPresentation = WorkspaceProviderSetupProgressPresentation(
            providerID: request.providerID,
            providerDisplayName: request.providerDisplayName,
            action: action,
            title: request.confirmation.progressTitle,
            bodyText: request.confirmation.progressBody,
            step: request.confirmation.initialProgress
        )

        Task { @MainActor in
            do {
                try await provider.performSetup(progress: { [weak self] step in
                    await self?.updateProgress(step: step)
                })

                await updateProgress(
                    step: WorkspaceProviderSetupProgress(
                        id: "continue",
                        label: "Continuing requested action"
                    )
                )
                let resume = pendingResume
                clearPendingState(keepProgress: true)
                await resume?()
                progressPresentation = nil
            } catch {
                let description = error.localizedDescription.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                errorMessage =
                    description.isEmpty
                    ? "Provider setup failed before it returned a detailed error. Open the relevant runtime settings and retry."
                    : description
                progressPresentation = nil
                clearPendingState(keepProgress: false)
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func updateProgress(step: WorkspaceProviderSetupProgress) async {
        guard let current = progressPresentation else { return }
        progressPresentation = WorkspaceProviderSetupProgressPresentation(
            providerID: current.providerID,
            providerDisplayName: current.providerDisplayName,
            action: current.action,
            title: current.title,
            bodyText: current.bodyText,
            step: step
        )
    }

    private func clearPendingState(keepProgress: Bool) {
        pendingProvider = nil
        pendingAction = nil
        pendingResume = nil
        confirmationRequest = nil
        if !keepProgress {
            progressPresentation = nil
        }
    }
}
