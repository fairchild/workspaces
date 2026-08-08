//
//  AutomationUIState.swift
//  WorkspaceManagerCore
//
//  Structural UI-state projection for `GET /v1/ui-state` (`ui.read`, operator scope):
//  the run-stable chrome an agent can assert on — selection, banner presence, sidebar
//  rows with status tokens, the attention pill, terminal tab/split topology — split
//  from a `volatile` sibling (model ids, shell-controlled tab titles) so golden diffs
//  compare only what is stable by design. `AutomationUIStateSnapshot` is a plain
//  Codable value so a future event stream (#1227) can embed the same representation.
//

import Foundation

/// The banner surfaces the main window can stack above the split view. Raw values are
/// the stable wire/golden identifiers; presence in `AutomationUIStateSnapshot.banners`
/// means the banner is currently rendered.
public enum AutomationUIBanner: String, Codable, CaseIterable, Sendable {
    case modelStoreDegraded = "model_store_degraded"
    case workspaceOrphanCleanup = "workspace_orphan_cleanup"
    case restoreSessions = "restore_sessions"
}

public enum AutomationUIStateSelectionKind: String, Codable, Sendable {
    case workspace
    case repo
    case none
}

/// What the main window's navigation currently targets. `name` is the workspace or
/// repo display name (stable across launches, unlike SwiftData ids); `nil` for `none`.
public struct AutomationUIStateSelection: Codable, Sendable, Equatable {
    public let kind: AutomationUIStateSelectionKind
    public let name: String?

    public init(kind: AutomationUIStateSelectionKind, name: String?) {
        self.kind = kind
        self.name = name
    }
}

/// One sidebar workspace row. `status` is the raw `WorkspaceStatus`; `attention` is the
/// agent-chrome status token (`running` / `attention` / `critical`) when the row carries
/// a live agent tone, `nil` when quiet — the same projection the sidebar dot renders.
public struct AutomationUIStateWorkspaceRow: Codable, Sendable, Equatable {
    public let name: String
    public let status: String
    public let isSelected: Bool
    public let attention: String?

    public init(name: String, status: String, isSelected: Bool, attention: String?) {
        self.name = name
        self.status = status
        self.isSelected = isSelected
        self.attention = attention
    }
}

/// One sidebar repo section with its workspace rows. Rows are name-sorted by contract:
/// the visual sidebar orders by last access (a timestamp — volatile by nature), so the
/// structural projection trades visual order for run-stable, diffable order.
public struct AutomationUIStateRepoSection: Codable, Sendable, Equatable {
    public let name: String
    public let isSelected: Bool
    public let workspaces: [AutomationUIStateWorkspaceRow]

    public init(name: String, isSelected: Bool, workspaces: [AutomationUIStateWorkspaceRow]) {
        self.name = name
        self.isSelected = isSelected
        self.workspaces = workspaces
    }
}

/// Terminal topology for the active scope: whether a terminal surface is attached, how
/// many tabs the active scope holds, and how many split panes hang off the active tab.
public struct AutomationUIStateTerminal: Codable, Sendable, Equatable {
    public let attached: Bool
    public let tabCount: Int
    public let splitCount: Int

    public init(attached: Bool, tabCount: Int, splitCount: Int) {
        self.attached = attached
        self.tabCount = tabCount
        self.splitCount = splitCount
    }
}

/// The run-stable structural state golden diffs compare. Every field here is expected
/// to be identical across two launches of the same fixture scenario on any machine;
/// anything that is not belongs in `AutomationUIStateVolatile` instead.
public struct AutomationUIStateSnapshot: Codable, Sendable, Equatable {
    public let selection: AutomationUIStateSelection
    /// Sorted `AutomationUIBanner` raw values for every banner currently rendered.
    public let banners: [String]
    /// The toolbar attention pill's rendered text (`"2 need you"`), `nil` when hidden.
    public let attentionPillText: String?
    /// Name-sorted repo sections with name-sorted workspace rows.
    public let sidebar: [AutomationUIStateRepoSection]
    public let terminal: AutomationUIStateTerminal

    public init(
        selection: AutomationUIStateSelection,
        banners: [String],
        attentionPillText: String?,
        sidebar: [AutomationUIStateRepoSection],
        terminal: AutomationUIStateTerminal
    ) {
        self.selection = selection
        self.banners = banners
        self.attentionPillText = attentionPillText
        self.sidebar = sidebar
        self.terminal = terminal
    }
}

/// The by-design unstable siblings of the snapshot: SwiftData ids (fresh per fixture
/// launch) and shell-controlled tab titles. On the wire for operator callers that want
/// to act on what they read; never golden-compared (`UIStateGolden` sees only `state`).
public struct AutomationUIStateVolatile: Codable, Sendable, Equatable {
    public let selectedWorkspaceID: UUID?
    public let selectedRepoID: UUID?
    /// Tab titles for the active scope, in tab order.
    public let tabTitles: [String]

    public init(selectedWorkspaceID: UUID?, selectedRepoID: UUID?, tabTitles: [String]) {
        self.selectedWorkspaceID = selectedWorkspaceID
        self.selectedRepoID = selectedRepoID
        self.tabTitles = tabTitles
    }
}

/// What the app's MainActor read produces for `ui.read`: the stable snapshot plus its
/// volatile sibling, before the controller wraps them with the handle's capabilities.
public struct AutomationUIStateCapture: Sendable, Equatable {
    public let state: AutomationUIStateSnapshot
    public let volatile: AutomationUIStateVolatile

    public init(state: AutomationUIStateSnapshot, volatile: AutomationUIStateVolatile) {
        self.state = state
        self.volatile = volatile
    }
}

/// Response for `GET /v1/ui-state` (`ui.read`, operator scope). `state` is the golden-
/// comparable structural snapshot; `volatile` carries the ids/titles excluded from
/// comparison by schema position rather than by a field-name allowlist.
public struct AutomationUIStateResult: Codable, Sendable, Equatable {
    public let state: AutomationUIStateSnapshot
    public let volatile: AutomationUIStateVolatile
    public let system: AutomationSystemDescriptor

    public init(
        state: AutomationUIStateSnapshot,
        volatile: AutomationUIStateVolatile,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.state = state
        self.volatile = volatile
        self.system = system
    }
}

/// Pure projection rules shared by the app's enumerator and the unit tests, so the
/// snapshot's normalization (ordering, token vocabulary, pill text) has one author.
public enum AutomationUIStateProjection {
    /// The sidebar status token for an agent run state — the same tone bucket the
    /// sidebar dot renders. Quiet tones (`idle`, `complete`) project no token.
    public static func statusToken(for run: AgentRunState) -> String? {
        switch AgentChromeProjection.runState(run).tone {
        case .running:
            return "running"
        case .attention:
            return "attention"
        case .critical:
            return "critical"
        case .hidden, .live, .active, .neutral:
            return nil
        }
    }

    /// The toolbar pill's rendered text for a resolved attention count; `nil` when the
    /// pill is hidden (count zero) — mirrors `NeedsYouToolbarPill`'s visibility rule.
    public static func attentionPillText(count: Int) -> String? {
        count > 0 ? "\(count) need you" : nil
    }

    /// Assembles a snapshot with the ordering contract applied: banner ids sorted,
    /// repo sections and workspace rows name-sorted. Callers pass rows in any order.
    public static func snapshot(
        selection: AutomationUIStateSelection,
        banners: [AutomationUIBanner],
        attentionCount: Int,
        sidebar: [AutomationUIStateRepoSection],
        terminal: AutomationUIStateTerminal
    ) -> AutomationUIStateSnapshot {
        AutomationUIStateSnapshot(
            selection: selection,
            banners: banners.map(\.rawValue).sorted(),
            attentionPillText: attentionPillText(count: attentionCount),
            sidebar:
                sidebar
                .map { section in
                    AutomationUIStateRepoSection(
                        name: section.name,
                        isSelected: section.isSelected,
                        workspaces: section.workspaces.sorted { $0.name < $1.name }
                    )
                }
                .sorted { $0.name < $1.name },
            terminal: terminal
        )
    }
}
