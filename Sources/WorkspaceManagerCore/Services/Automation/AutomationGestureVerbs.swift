//
//  AutomationGestureVerbs.swift
//  WorkspaceManagerCore
//
//  The gesture-verb layer — the single place the "verbs = clicks" rule is enforced (`[A2]`).
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

    /// Resolve a stable workspace id (a `workspace.read` id) to a target, or `nil` if the app tracks
    /// no such workspace. Read-only — it never mutates selection.
    private let resolveWorkspace: @MainActor (UUID) -> WorkspaceTarget?

    /// Drive the real selection gesture for `target` — write the selection binding whose setter
    /// attaches the terminal and requests focus — and report back what the UI did. This closure is
    /// the app's actual click path; the layer holds nothing else.
    private let performSelection: @MainActor (WorkspaceTarget) -> AutomationWorkspaceSelectEffect

    public init(
        resolveWorkspace: @escaping @MainActor (UUID) -> WorkspaceTarget?,
        performSelection: @escaping @MainActor (WorkspaceTarget) -> AutomationWorkspaceSelectEffect
    ) {
        self.resolveWorkspace = resolveWorkspace
        self.performSelection = performSelection
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
}
