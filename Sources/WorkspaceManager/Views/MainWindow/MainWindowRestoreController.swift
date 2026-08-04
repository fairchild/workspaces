//
//  MainWindowRestoreController.swift
//  WorkspaceManager
//
//  The main window's restore-banner flow: whether a computed plan is worth offering, what
//  acting on it persists, and what each restored surface launches with. Planning and the
//  plan's own predicates live in `TerminalRestorePlanner`; this owns the order the window
//  applies them in and the launch mapping, so both are assertable without a window.
//

import Foundation
import WorkspaceManagerCore

/// Restore-banner state for the previous run's surfaces, held in one `@State`.
///
/// The handled-run id lives in `@AppStorage` rather than here: it must outlive the window so
/// a later launch that selects the same prior run does not re-offer it.
struct MainWindowRestoreState: Equatable {
    private(set) var plan: RestorePlan?
    private(set) var bannerDismissed = false

    /// The plan the banner should show, or `nil` when there is nothing to offer — no plan, an
    /// empty one, or one the user already acted on this launch.
    var bannerPlan: RestorePlan? {
        guard let plan, !plan.surfaces.isEmpty, !bannerDismissed else { return nil }
        return plan
    }

    mutating func offer(_ plan: RestorePlan) {
        self.plan = plan
    }

    mutating func dismissBanner() {
        bannerDismissed = true
    }
}

@MainActor
struct MainWindowRestoreController {
    /// Why a computed plan does or does not raise the restore banner.
    ///
    /// The cases are checked in this order and the first match wins, so an empty plan reports
    /// as empty even when its run was also already handled. That ordering is what the log line
    /// names, and it is the reason this is a decision rather than three independent predicates.
    enum PlanDisposition: Equatable {
        case noRestorableSurfaces
        case alreadyHandled(previousRunID: String?)
        case onlyDuplicatesLaunchSeed
        case offer
    }

    func disposition(
        for plan: RestorePlan,
        handledRunID: String,
        seedKey: HostTerminalSessionKey,
        seedDirectory: URL
    ) -> PlanDisposition {
        if plan.surfaces.isEmpty {
            return .noRestorableSurfaces
        }
        // An empty stored id means "nothing handled yet", not "handled by a run named empty".
        if plan.wasHandled(handledRunID: handledRunID.isEmpty ? nil : handledRunID) {
            return .alreadyHandled(previousRunID: plan.previousRunID)
        }
        if !plan.offersMoreThanLaunchSeed(seedKey: seedKey, seedDirectory: seedDirectory) {
            return .onlyDuplicatesLaunchSeed
        }
        return .offer
    }

    /// The prior-run id that acting on this plan should persist, or `nil` when the plan has no
    /// run identity to remember. The banner is dismissed either way.
    func handledRunID(for plan: RestorePlan) -> String? {
        plan.previousRunID
    }

    /// Dev-only drive hook for headless restore verification: with `WORKSPACES_RESTORE_AUTORUN=1`
    /// a planned restore executes as if the user clicked Restore, so smoke scripts can exercise
    /// the real resume path without desktop input.
    func isAutorunRequested(environment: [String: String]) -> Bool {
        environment["WORKSPACES_RESTORE_AUTORUN"] == "1"
    }

    /// Every key the plan owns. A pre-restore seed may hold one of these, and it is retired
    /// first so the restored surface is created fresh rather than reusing the seed's session.
    func ownedSessionKeys(in plan: RestorePlan) -> Set<HostTerminalSessionKey> {
        Set(plan.surfaces.map(\.key))
    }

    /// Directories whose deterministic tmux session must be killed before restore. The planner
    /// only chose resume because the prior tmux session is gone, so a live session on that name
    /// can only be this launch's seed artifact — killing it stops the resume surface
    /// `-A`-attaching to a leftover shell instead of starting fresh.
    func tmuxSessionDirectoriesToKill(in plan: RestorePlan) -> [URL] {
        plan.surfaces.compactMap { surface in
            guard case .resumeClaude = surface.action else { return nil }
            return surface.directory
        }
    }

    /// What a restored surface launches with. Reattach and fresh surfaces are a plain
    /// directory-backed launch — the deterministic tmux name reattaches a surviving session on
    /// its own — while a resume surface gets `claude --resume` as initial input so it runs
    /// through the login shell with the correct PATH and hook env.
    func initialCommand(for action: RestoreSurfaceAction) -> String? {
        switch action {
        case .reattachTmux, .freshShell:
            return nil
        case .resumeClaude(let agentSessionID):
            return RestoreLaunchCommand.claudeResume(sessionID: agentSessionID)
        }
    }
}
