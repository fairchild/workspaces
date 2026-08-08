//
//  AutomationGestureVerbs.swift
//  WorkspaceManagerCore
//
//  The gesture-verb layer — the single place the "verbs = clicks" rule is enforced.
//
//  Every mutation verb enters the same UI gesture the equivalent user action does. This layer is
//  constructed with *only* gesture closures — the app's real UI entry points (for `workspace.select`,
//  the selection binding whose setter attaches the terminal and requests focus) — and holds no
//  service, backend, or SwiftData handle. That absence is the guarantee: a verb here structurally
//  cannot reach a data-layer write, so it cannot produce a snapshot that lies or misroute the next
//  input into a stale PTY. When no window is live the app installs no gesture layer at all and the
//  controller reports `unsupported`, never a fallback.
//

import Foundation

/// The structured outcome of a gesture verb. `AutomationGestureOutcomeKind` is the wire-facing subset
/// (`completed`/`confirmation_required`); `unsupported` and `notFound` fail closed with stable error
/// codes instead of riding the success envelope. Every verb the layer grows returns this same enum,
/// so the outcome contract has one definition.
public enum AutomationWorkspaceSelectOutcome: Sendable, Equatable {
    /// The gesture ran through the real selection path; `effect` reports what the UI did.
    case completed(AutomationWorkspaceSelectEffect)
    /// The gesture would surface a modal; the message is what the user would confirm. `workspace.select`
    /// never raises this today (selection has no confirmation dialog), but the shared verb contract
    /// models it for sibling verbs (e.g. a destructive close) so dialogs become data, never a hang.
    case confirmationRequired(String)
    /// The verb cannot run in the current context. For selection the dominant cause is "no live
    /// window," which the controller detects by the absence of the gesture layer.
    case unsupported(String)
    /// The workspace id resolves to nothing the app tracks. Mapped to `invalid_request` at the wire.
    case notFound
}

public enum AutomationWorkspaceCreateOutcome: Sendable, Equatable {
    /// The create gesture ran through the real UI path and produced a selected, attached workspace.
    case completed(AutomationWorkspaceCreateEffect)
    /// The gesture reached a modal or setup confirmation. The caller gets the confirmation details
    /// as data instead of waiting on UI it cannot answer.
    case confirmationRequired(AutomationConfirmationRequirement)
    /// The verb cannot run in the current context, most often because no live window/sidebar is bound.
    case unsupported(String)
    /// The repo id resolves to nothing the app tracks. Mapped to `invalid_request` at the wire.
    case notFound
    /// The request named something the UI path cannot create, such as an unknown provider.
    case invalidRequest(String)
}

public enum AutomationWorkspaceArchiveOutcome: Sendable, Equatable {
    /// The archive gesture ran through the real UI path and persisted the archive state.
    case completed(AutomationWorkspaceArchiveEffect)
    /// The gesture reached a modal or setup confirmation. The caller gets the confirmation details
    /// as data instead of waiting on UI it cannot answer.
    case confirmationRequired(AutomationConfirmationRequirement)
    /// The verb cannot run in the current context, most often because no live window/sidebar is bound.
    case unsupported(String)
    /// The workspace id resolves to nothing the app tracks. Mapped to `invalid_request` at the wire.
    case notFound
    /// The workspace still has a live terminal that did not exit before the lifecycle timeout — the
    /// transient arm. Mapped to `terminal_active` with `retryable: true` at the wire.
    case terminalActive(String)
    /// A terminal close was blocked by the runtime's close-confirmation (a live process that would
    /// raise the headlessly-unanswerable Ghostty dialog). Mapped to `close_blocked_by_confirmation`
    /// with `retryable: false` at the wire — retrying cannot dismiss the dialog.
    case closeBlockedByConfirmation(String)
}

@MainActor
public final class AutomationGestureVerbs {
    /// The minimum a verb needs to target and describe a workspace, projected out of the live
    /// SwiftData model by the app so this layer never touches the model directly. `isArchived`
    /// lets the layer stay honest about the archived branch (selection navigates to the repo
    /// overview rather than attaching a terminal).
    public struct WorkspaceTarget: Sendable, Equatable {
        public let workspaceID: UUID
        public let name: String
        public let isArchived: Bool

        public init(workspaceID: UUID, name: String, isArchived: Bool) {
            self.workspaceID = workspaceID
            self.name = name
            self.isArchived = isArchived
        }
    }

    /// The minimum the create verb needs to target a repo after `workspace.read` projects it.
    /// The app resolves this from live SwiftData models before the gesture runs.
    public struct RepoTarget: Sendable, Equatable {
        public let repoID: UUID
        public let name: String
        public let path: String

        public init(repoID: UUID, name: String, path: String) {
            self.repoID = repoID
            self.name = name
            self.path = path
        }
    }

    /// Resolve a stable workspace id (a `workspace.read` id) to a target, or `nil` if the app tracks
    /// no such workspace. Read-only — it never mutates selection.
    private let resolveWorkspace: @MainActor (UUID) -> WorkspaceTarget?
    /// Resolve a stable repo id (a `workspace.read` repo id) to a target. Read-only.
    private let resolveRepo: (@MainActor (UUID) -> RepoTarget?)?

    /// Drive the real selection gesture for `target` — write the selection binding whose setter
    /// attaches the terminal and requests focus — and report back what the UI did. This closure is
    /// the app's actual click path; the layer holds nothing else.
    private let performSelection: @MainActor (WorkspaceTarget) -> AutomationWorkspaceSelectEffect
    /// Drive the real sidebar create gesture for `command` and report what the UI did.
    private let performCreation:
        (@MainActor (RepoTarget, AutomationWorkspaceCreateCommand) async -> AutomationWorkspaceCreateOutcome)?
    /// Drive the real sidebar archive gesture for `target` (with the command's teardown option)
    /// and report what the UI did.
    private let performArchive:
        (@MainActor (WorkspaceTarget, AutomationWorkspaceArchiveCommand) async -> AutomationWorkspaceArchiveOutcome)?

    public init(
        resolveWorkspace: @escaping @MainActor (UUID) -> WorkspaceTarget?,
        performSelection: @escaping @MainActor (WorkspaceTarget) -> AutomationWorkspaceSelectEffect,
        resolveRepo: (@MainActor (UUID) -> RepoTarget?)? = nil,
        performCreation: (
            @MainActor (RepoTarget, AutomationWorkspaceCreateCommand) async -> AutomationWorkspaceCreateOutcome
        )? = nil,
        performArchive: (
            @MainActor (WorkspaceTarget, AutomationWorkspaceArchiveCommand) async -> AutomationWorkspaceArchiveOutcome
        )? = nil
    ) {
        self.resolveWorkspace = resolveWorkspace
        self.performSelection = performSelection
        self.resolveRepo = resolveRepo
        self.performCreation = performCreation
        self.performArchive = performArchive
    }

    /// `workspace.select`: enter the same selection path a sidebar click takes. Resolves the id, then
    /// drives the real binding gesture — no service call, no data-layer flip. A completed selection of
    /// a live local workspace attaches (and focuses) its terminal exactly as the click would; that
    /// attach is what keeps a following input from landing in the previously selected PTY.
    public func selectWorkspace(_ workspaceID: UUID) -> AutomationWorkspaceSelectOutcome {
        guard let target = resolveWorkspace(workspaceID) else {
            return .notFound
        }
        let effect = performSelection(target)
        return .completed(effect)
    }

    /// `workspace.create`: enter the same sidebar helper the New Workspace sheet and smoke driver
    /// use. Resolves the repo id, then drives only the supplied gesture closure. A missing create
    /// closure means the live window did not install a create path, so the verb fails closed.
    public func createWorkspace(
        _ command: AutomationWorkspaceCreateCommand
    ) async -> AutomationWorkspaceCreateOutcome {
        guard let resolveRepo, let performCreation else {
            return .unsupported("No WorkSpaces sidebar is attached; workspace.create requires a live window.")
        }
        guard let target = resolveRepo(command.repoID) else {
            return .notFound
        }
        return await performCreation(target, command)
    }

    /// `workspace.archive`: enter the same sidebar archive action the row menu uses. Resolves the
    /// workspace id, then drives only the supplied gesture closure (which owns the command's
    /// optional terminal teardown). A missing archive closure means the live window did not install
    /// an archive path, so the verb fails closed.
    public func archiveWorkspace(
        _ command: AutomationWorkspaceArchiveCommand
    ) async -> AutomationWorkspaceArchiveOutcome {
        guard let performArchive else {
            return .unsupported("No WorkSpaces sidebar is attached; workspace.archive requires a live window.")
        }
        guard let target = resolveWorkspace(command.workspaceID) else {
            return .notFound
        }
        return await performArchive(target, command)
    }
}
