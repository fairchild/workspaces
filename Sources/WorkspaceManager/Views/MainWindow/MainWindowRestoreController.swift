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

    /// How the pre-restore tmux pass is split: what may die, and what was left alone because
    /// this launch cannot claim it.
    struct TmuxTeardownScope: Equatable {
        let kill: [String]
        let skippedUnowned: [String]
    }

    /// Tmux session names to kill before restore, scoped to sessions this launch owns.
    ///
    /// Killing exists so a resume surface starts fresh instead of `-A`-attaching to the shell
    /// its pre-restore seed left behind. The candidate name is the resume surface's directory
    /// derivation, and that derivation is the whole problem: `-L workspaces` is a same-user
    /// shared socket, so the same name can equally belong to a session a person or another
    /// tool started. The planner concluded "the prior tmux session is gone" at plan time from
    /// recorded continuity rows, which says nothing about who holds that name now (#1267).
    ///
    /// So a candidate only dies when it matches a session this launch is holding —
    /// `ownedTmuxSessionNames`, the effective names of the sessions about to be retired.
    /// Everything else is reported in `skippedUnowned` for the caller to log and left running.
    ///
    /// A name another surface is reattaching to is never a candidate at all: a resume and a
    /// reattach surface can share a directory, and the derived name would then be the reattach
    /// target (#1233).
    func tmuxSessionNamesToKill(
        in plan: RestorePlan,
        ownedTmuxSessionNames: Set<String>,
        sessionName: (URL) -> String = { GhosttyTerminalConfig.tmuxSessionName(for: $0) }
    ) -> TmuxTeardownScope {
        let reattachTargets = Set(
            plan.surfaces.compactMap { surface -> String? in
                guard case .reattachTmux(let name) = surface.action else { return nil }
                return name
            }
        )
        let candidates = plan.surfaces.compactMap { surface -> String? in
            guard case .resumeClaude = surface.action else { return nil }
            let name = sessionName(surface.directory)
            return reattachTargets.contains(name) ? nil : name
        }
        return TmuxTeardownScope(
            kill: candidates.filter { ownedTmuxSessionNames.contains($0) },
            skippedUnowned: candidates.filter { !ownedTmuxSessionNames.contains($0) }
        )
    }

    /// The directory-derived tmux names resume surfaces will `new-session -A`-launch on.
    /// The wiring probes these after the pre-restore kill pass: a name still alive there
    /// was excluded from the kill list because another surface reattaches to it (shared
    /// directory, #1233), so the resume launch would join that live session.
    func resumeLaunchSessionNames(
        in plan: RestorePlan,
        sessionName: (URL) -> String = { GhosttyTerminalConfig.tmuxSessionName(for: $0) }
    ) -> Set<String> {
        Set(
            plan.surfaces.compactMap { surface -> String? in
                guard case .resumeClaude = surface.action else { return nil }
                return sessionName(surface.directory)
            }
        )
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

    /// `initialCommand(for:)` guarded by the probe-before-launch check: a resume whose
    /// `-A` target is in `liveSessionNames` attaches to an existing session — one another
    /// surface owns — so injecting the command would type `claude --resume` into that
    /// shared shell. The surface degrades to a plain attach instead (#1233).
    func initialCommand(
        for surface: RestoreSurfacePlan,
        liveSessionNames: Set<String>,
        sessionName: (URL) -> String = { GhosttyTerminalConfig.tmuxSessionName(for: $0) }
    ) -> String? {
        guard let command = initialCommand(for: surface.action) else { return nil }
        guard !liveSessionNames.contains(sessionName(surface.directory)) else { return nil }
        return command
    }

    /// The tmux session name a restored surface must launch on, or `nil` to derive from the
    /// launch directory. A reattach surface targets the probed name from its continuity row —
    /// re-deriving from the directory would start a fresh session in the fallback directory
    /// and strand the surviving one whenever the recorded directory is gone (#1233).
    func tmuxSessionNameOverride(for action: RestoreSurfaceAction) -> String? {
        guard case .reattachTmux(let sessionName) = action else { return nil }
        return sessionName
    }

    /// The host-session identity a restored surface takes on, or `nil` to mint a fresh one.
    ///
    /// Reattaching joins processes that outlived the app, and those processes still export the
    /// `WORKSPACES_HOST_SESSION_ID` the surface carried in the previous run. A fresh identity
    /// there is a rename nobody inside the pane hears about: every hook post keeps arriving
    /// under the recorded id, the listener finds no registration for it and drops the event, so
    /// status ingestion goes dead for exactly the sessions continuity exists to preserve
    /// (#1397). Adopting the recorded id makes identity survive with the pty, and keeps the
    /// session on one `terminal_sessions` row across the restart instead of stranding the old
    /// one beside a new duplicate.
    ///
    /// A resume or fresh surface starts a shell that inherits this run's environment, so its
    /// identity is genuinely new and the recorded id is not its to claim.
    func adoptedHostSessionID(for surface: RestoreSurfacePlan) -> UUID? {
        guard case .reattachTmux = surface.action else { return nil }
        return surface.hostSessionID
    }
}
