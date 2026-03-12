//
//  LumeSetupCoordinator.swift
//  WorkspaceManager
//
//  First-use Lume setup orchestration for workspace actions.
//

import Foundation
import WorkspaceManagerCore

enum PendingLumeAction: Equatable {
    case createWorkspace(name: String, guestOS: WorkspaceGuestOS)
    case openTerminal(workspaceName: String)
    case openDesktop(workspaceName: String)
    case startWorkspace(workspaceName: String)

    var summary: String {
        switch self {
        case .createWorkspace(let name, let guestOS):
            return "Create \(guestOS.label) workspace '\(name)'"
        case .openTerminal(let workspaceName):
            return "Open terminal for '\(workspaceName)'"
        case .openDesktop(let workspaceName):
            return "Open desktop for '\(workspaceName)'"
        case .startWorkspace(let workspaceName):
            return "Start '\(workspaceName)'"
        }
    }
}

struct LumeSetupConfirmationRequest: Identifiable, Equatable {
    let id = UUID()
    let action: PendingLumeAction
    let runtimeState: LumeRuntimeState
    let hostProfileDisplayName: String?

    var title: String {
        switch runtimeState {
        case .repairRequired:
            return "Repair macOS VM Support"
        default:
            return "Set Up macOS VM Support"
        }
    }

    var primaryButtonTitle: String {
        switch runtimeState {
        case .repairRequired:
            return "Repair Lume and Continue"
        default:
            return "Install Lume and Continue"
        }
    }

    var explanatorySteps: [String] {
        [
            "Install the official Lume CLI in ~/.local/bin",
            "Install and load the user LaunchAgent on localhost:7777",
            "Verify the daemon is healthy",
            "Continue: \(action.summary)",
        ]
    }

    var hostMatchDescription: String? {
        hostProfileDisplayName.map { "Default macOS VM: \($0)" }
    }
}

struct LumeSetupProgressPresentation: Identifiable, Equatable {
    let id = UUID()
    let action: PendingLumeAction
    var step: LumeRuntimeSetupStep
}

@MainActor
final class LumeSetupCoordinator: ObservableObject {
    @Published var confirmationRequest: LumeSetupConfirmationRequest?
    @Published var progressPresentation: LumeSetupProgressPresentation?
    @Published var errorMessage: String?

    private let runtimeService: any LumeRuntimeServiceProtocol
    private var pendingAction: PendingLumeAction?
    private var pendingResume: (@MainActor () async -> Void)?

    init(runtimeService: any LumeRuntimeServiceProtocol = LumeRuntimeService.shared) {
        self.runtimeService = runtimeService
    }

    func prepareIfNeeded(
        for action: PendingLumeAction,
        resume: @escaping @MainActor () async -> Void
    ) async throws -> Bool {
        let snapshot = await runtimeService.snapshot()

        switch snapshot.state {
        case .ready:
            return false
        case .setupRequired, .repairRequired:
            pendingAction = action
            pendingResume = resume
            confirmationRequest = LumeSetupConfirmationRequest(
                action: action,
                runtimeState: snapshot.state,
                hostProfileDisplayName: snapshot.defaultMacOSImage?.profileDisplayName
                    ?? snapshot.hostProfile?.displayName
            )
            return true
        case .unsupportedHost:
            throw LumeRuntimeError.unsupportedHost(
                snapshot.reason ?? "Lume is unsupported on this Mac."
            )
        case .installing, .verifying:
            return true
        }
    }

    func cancelPendingAction() {
        confirmationRequest = nil
        progressPresentation = nil
        pendingAction = nil
        pendingResume = nil
    }

    func confirmAndContinue() {
        guard let action = pendingAction else { return }

        confirmationRequest = nil
        progressPresentation = LumeSetupProgressPresentation(
            action: action,
            step: .checkingHost
        )

        Task { @MainActor in
            do {
                let setupSnapshot = await runtimeService.snapshot()
                let progressHandler: LumeRuntimeProgressHandler = { [weak self] step in
                    await self?.updateProgress(step: step)
                }
                switch setupSnapshot.state {
                case .setupRequired:
                    _ = try await runtimeService.installIfNeeded(progress: progressHandler)
                case .repairRequired:
                    _ = try await runtimeService.repairInstallation(progress: progressHandler)
                case .ready:
                    _ = try await runtimeService.verifyInstallation(progress: progressHandler)
                case .unsupportedHost:
                    throw LumeRuntimeError.unsupportedHost(
                        setupSnapshot.reason ?? "Lume is unsupported on this Mac."
                    )
                case .installing, .verifying:
                    break
                }

                await updateProgress(step: .continuingRequestedAction)
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
                    ? "Lume setup failed before it returned a detailed error. Open Settings > VM Runtime and run Verify or Repair."
                    : description
                progressPresentation = nil
                clearPendingState(keepProgress: false)
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func updateProgress(step: LumeRuntimeSetupStep) async {
        guard let current = progressPresentation else { return }
        progressPresentation = LumeSetupProgressPresentation(
            action: current.action,
            step: step
        )
    }

    private func clearPendingState(keepProgress: Bool) {
        pendingAction = nil
        pendingResume = nil
        confirmationRequest = nil
        if !keepProgress {
            progressPresentation = nil
        }
    }
}
