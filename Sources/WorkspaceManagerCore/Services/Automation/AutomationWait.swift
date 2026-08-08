//
//  AutomationWait.swift
//  WorkspaceManagerCore
//
//  Typed server-side wait for `POST /v1/wait` (operator scope): the condition vocabulary,
//  the validated bounded-timeout plan, and the deterministic wait engine. The engine turns
//  the sleep/re-poll loops smoke scripts hand-roll into one server-side evaluation with a
//  typed outcome — never an open-ended block. The condition vocabulary is shared design
//  surface for the future events endpoint (#1227): an event stream emits the same
//  observations a wait polls for.
//

import Foundation

/// The wire vocabulary for `POST /v1/wait`'s `for` field. Raw values are the stable wire
/// identifiers; the future events endpoint reuses this vocabulary for its event kinds.
public enum AutomationWaitConditionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case surfaceAttached = "surface_attached"
    case workspaceSelected = "workspace_selected"
    case surfaceTextMatches = "surface_text_matches"
    case promptReady = "prompt_ready"
}

/// The optional `predicate` object narrowing a wait condition to a target. Which fields are
/// required, optional, or rejected depends on the condition — `AutomationWaitPlan.resolve`
/// is the single validator, so a predicate field that does not apply fails typed
/// (`invalid_request`) instead of being silently ignored.
public struct AutomationWaitPredicate: Codable, Sendable, Equatable {
    public let surfaceID: String?
    public let workspaceID: String?
    public let pattern: String?

    public init(surfaceID: String? = nil, workspaceID: String? = nil, pattern: String? = nil) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.pattern = pattern
    }
}

/// Wire body for `POST /v1/wait`. `condition` rides the wire as `for` (a Swift keyword);
/// `timeoutMS` is optional and bounded — see `AutomationWaitPlan.resolve` for defaults and
/// the ceiling.
public struct AutomationWaitRequest: Codable, Sendable, Equatable {
    public let condition: String
    public let predicate: AutomationWaitPredicate?
    public let timeoutMS: Int?

    enum CodingKeys: String, CodingKey {
        case condition = "for"
        case predicate
        case timeoutMS
    }

    public init(condition: String, predicate: AutomationWaitPredicate? = nil, timeoutMS: Int? = nil) {
        self.condition = condition
        self.predicate = predicate
        self.timeoutMS = timeoutMS
    }
}

/// The typed wait outcome — never a bare boolean, mirroring `AutomationGestureOutcomeKind`.
/// `satisfied`: the condition held on an evaluation tick. `timed_out`: the bounded window
/// elapsed with the condition still pending; the caller re-arms (repeat the request) if it
/// has budget left. `not_applicable`: current state already proves the condition cannot be
/// satisfied as posed (e.g. waiting for selection of an archived workspace) — retrying the
/// identical wait is wasted work until that state changes.
public enum AutomationWaitOutcomeKind: String, Codable, Sendable, Equatable {
    case satisfied
    case timedOut = "timed_out"
    case notApplicable = "not_applicable"
}

/// What the final evaluation tick observed, reported on every outcome so a timeout is
/// diagnosable from the response alone. Sparse by design: only the fields relevant to the
/// condition are present; an absent field means "not part of this condition", never "zero".
/// Never carries terminal text — `surface_text_matches` reports whether the bounded read
/// matched, not what the terminal said, so the audit log stays free of terminal content.
public struct AutomationWaitObservation: Codable, Sendable, Equatable {
    /// Whether a WorkSpaces window (tile tree) was attached at evaluation time.
    public let windowAttached: Bool?
    /// Whether the predicate's surface resolved to a live terminal tile.
    public let surfaceLive: Bool?
    public let surfaceAttached: Bool?
    public let attachedSurfaceID: String?
    public let workspaceSelected: Bool?
    public let selectedWorkspaceID: UUID?
    /// True when the predicate's workspace exists but is archived — the `not_applicable`
    /// proof for `workspace_selected`; false when it exists un-archived; absent when the
    /// predicate named no workspace or the id is not tracked.
    public let targetWorkspaceArchived: Bool?
    public let textMatched: Bool?
    public let promptReady: Bool?

    public init(
        windowAttached: Bool? = nil,
        surfaceLive: Bool? = nil,
        surfaceAttached: Bool? = nil,
        attachedSurfaceID: String? = nil,
        workspaceSelected: Bool? = nil,
        selectedWorkspaceID: UUID? = nil,
        targetWorkspaceArchived: Bool? = nil,
        textMatched: Bool? = nil,
        promptReady: Bool? = nil
    ) {
        self.windowAttached = windowAttached
        self.surfaceLive = surfaceLive
        self.surfaceAttached = surfaceAttached
        self.attachedSurfaceID = attachedSurfaceID
        self.workspaceSelected = workspaceSelected
        self.selectedWorkspaceID = selectedWorkspaceID
        self.targetWorkspaceArchived = targetWorkspaceArchived
        self.textMatched = textMatched
        self.promptReady = promptReady
    }
}

/// Response for `POST /v1/wait`. Echoes the condition (as `for`) and both timeout figures so
/// a clamped request is visible on the wire: `requestedTimeoutMS` is what the caller asked,
/// `effectiveTimeoutMS` what the server enforced (the `waitMaxTimeoutMS` ceiling), the same
/// requested-vs-effective reporting `surface.read` uses for its line clamp.
public struct AutomationWaitResult: Codable, Sendable, Equatable {
    public let condition: AutomationWaitConditionKind
    public let outcome: AutomationWaitOutcomeKind
    public let waitedMS: Int
    public let requestedTimeoutMS: Int
    public let effectiveTimeoutMS: Int
    public let observed: AutomationWaitObservation
    public let system: AutomationSystemDescriptor

    enum CodingKeys: String, CodingKey {
        case condition = "for"
        case outcome
        case waitedMS
        case requestedTimeoutMS
        case effectiveTimeoutMS
        case observed
        case system
    }

    public init(
        condition: AutomationWaitConditionKind,
        outcome: AutomationWaitOutcomeKind,
        waitedMS: Int,
        requestedTimeoutMS: Int,
        effectiveTimeoutMS: Int,
        observed: AutomationWaitObservation,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.condition = condition
        self.outcome = outcome
        self.waitedMS = waitedMS
        self.requestedTimeoutMS = requestedTimeoutMS
        self.effectiveTimeoutMS = effectiveTimeoutMS
        self.observed = observed
        self.system = system
    }
}

/// A validated wait condition: predicate fields parsed, UUID-shaped, and scoped to the
/// condition they apply to. Produced only by `AutomationWaitPlan.resolve`, so the evaluator
/// never sees a malformed target.
public enum AutomationWaitCondition: Sendable, Equatable {
    case surfaceAttached(surfaceID: UUID?)
    case workspaceSelected(workspaceID: UUID?)
    case surfaceTextMatches(surfaceID: UUID, pattern: String)
    case promptReady(surfaceID: UUID)

    public var kind: AutomationWaitConditionKind {
        switch self {
        case .surfaceAttached:
            return .surfaceAttached
        case .workspaceSelected:
            return .workspaceSelected
        case .surfaceTextMatches:
            return .surfaceTextMatches
        case .promptReady:
            return .promptReady
        }
    }
}

/// The resolved wait: a validated condition plus the bounded timeout pair. `resolve` is the
/// one place wait requests are validated, so every malformed shape fails typed at the wire
/// (`invalid_request`) before any controller state is read.
public struct AutomationWaitPlan: Sendable, Equatable {
    public let condition: AutomationWaitCondition
    public let requestedTimeoutMS: Int
    public let effectiveTimeoutMS: Int

    public init(condition: AutomationWaitCondition, requestedTimeoutMS: Int, effectiveTimeoutMS: Int) {
        self.condition = condition
        self.requestedTimeoutMS = requestedTimeoutMS
        self.effectiveTimeoutMS = effectiveTimeoutMS
    }

    public static func resolve(_ request: AutomationWaitRequest) throws -> AutomationWaitPlan {
        guard let kind = AutomationWaitConditionKind(rawValue: request.condition) else {
            let vocabulary = AutomationWaitConditionKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw AutomationServiceError(
                .invalidRequest,
                "Unsupported wait condition '\(request.condition)'. Use one of: \(vocabulary)."
            )
        }
        let requested = request.timeoutMS ?? AutomationAPI.waitDefaultTimeoutMS
        guard requested > 0 else {
            throw AutomationServiceError(.invalidRequest, "Request 'timeoutMS' must be greater than zero.")
        }
        let effective = min(requested, AutomationAPI.waitMaxTimeoutMS)
        let predicate = request.predicate ?? AutomationWaitPredicate()

        let condition: AutomationWaitCondition
        switch kind {
        case .surfaceAttached:
            try rejectPredicateField(predicate.workspaceID, named: "workspaceID", for: kind)
            try rejectPredicateField(predicate.pattern, named: "pattern", for: kind)
            condition = .surfaceAttached(surfaceID: try optionalUUID(predicate.surfaceID, named: "surfaceID"))
        case .workspaceSelected:
            try rejectPredicateField(predicate.surfaceID, named: "surfaceID", for: kind)
            try rejectPredicateField(predicate.pattern, named: "pattern", for: kind)
            condition = .workspaceSelected(workspaceID: try optionalUUID(predicate.workspaceID, named: "workspaceID"))
        case .surfaceTextMatches:
            try rejectPredicateField(predicate.workspaceID, named: "workspaceID", for: kind)
            condition = .surfaceTextMatches(
                surfaceID: try requiredUUID(predicate.surfaceID, named: "surfaceID", for: kind),
                pattern: try validatedPattern(predicate.pattern, for: kind)
            )
        case .promptReady:
            try rejectPredicateField(predicate.workspaceID, named: "workspaceID", for: kind)
            try rejectPredicateField(predicate.pattern, named: "pattern", for: kind)
            condition = .promptReady(surfaceID: try requiredUUID(predicate.surfaceID, named: "surfaceID", for: kind))
        }
        return AutomationWaitPlan(condition: condition, requestedTimeoutMS: requested, effectiveTimeoutMS: effective)
    }

    private static func rejectPredicateField(
        _ value: String?,
        named name: String,
        for kind: AutomationWaitConditionKind
    ) throws {
        guard value == nil else {
            throw AutomationServiceError(
                .invalidRequest,
                "Predicate '\(name)' does not apply to wait condition '\(kind.rawValue)'."
            )
        }
    }

    private static func optionalUUID(_ value: String?, named name: String) throws -> UUID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw AutomationServiceError(.invalidRequest, "Predicate '\(name)' must be a UUID.")
        }
        return uuid
    }

    private static func requiredUUID(
        _ value: String?,
        named name: String,
        for kind: AutomationWaitConditionKind
    ) throws -> UUID {
        guard let value else {
            throw AutomationServiceError(
                .invalidRequest,
                "Wait condition '\(kind.rawValue)' requires predicate '\(name)'."
            )
        }
        guard let uuid = UUID(uuidString: value) else {
            throw AutomationServiceError(.invalidRequest, "Predicate '\(name)' must be a UUID.")
        }
        return uuid
    }

    private static func validatedPattern(_ value: String?, for kind: AutomationWaitConditionKind) throws -> String {
        guard let value, !value.isEmpty else {
            throw AutomationServiceError(
                .invalidRequest,
                "Wait condition '\(kind.rawValue)' requires a non-empty predicate 'pattern'."
            )
        }
        guard value.utf8.count <= AutomationAPI.waitPatternMaxUTF8Bytes else {
            throw AutomationServiceError(
                .invalidRequest,
                "Predicate 'pattern' exceeds the \(AutomationAPI.waitPatternMaxUTF8Bytes)-byte limit."
            )
        }
        do {
            _ = try NSRegularExpression(pattern: value)
        } catch {
            throw AutomationServiceError(.invalidRequest, "Predicate 'pattern' is not a valid regular expression.")
        }
        return value
    }
}

/// What one evaluation tick concluded. `pending` keeps the engine polling; the other two end
/// the wait immediately with the corresponding typed outcome.
public enum AutomationWaitProbe: Sendable, Equatable {
    case satisfied(AutomationWaitObservation)
    case pending(AutomationWaitObservation)
    case notApplicable(AutomationWaitObservation)
}

/// The engine's terminal state: the typed outcome, how long the wait actually ran, and what
/// the final tick observed.
public struct AutomationWaitVerdict: Sendable, Equatable {
    public let outcome: AutomationWaitOutcomeKind
    public let waitedMS: Int
    public let observed: AutomationWaitObservation

    public init(outcome: AutomationWaitOutcomeKind, waitedMS: Int, observed: AutomationWaitObservation) {
        self.outcome = outcome
        self.waitedMS = waitedMS
        self.observed = observed
    }
}

/// Deterministic time seam for the wait engine: a monotonic milliseconds reading plus a
/// suspending sleep. Production uses `ContinuousClock`; tests advance a virtual counter so
/// every outcome is exercised without wall-clock sleeps.
public struct AutomationWaitTimeSource: Sendable {
    public let nowMS: @Sendable () -> Int64
    public let sleepMS: @Sendable (Int64) async -> Void

    public init(
        nowMS: @escaping @Sendable () -> Int64,
        sleepMS: @escaping @Sendable (Int64) async -> Void
    ) {
        self.nowMS = nowMS
        self.sleepMS = sleepMS
    }

    public static func continuous() -> AutomationWaitTimeSource {
        let clock = ContinuousClock()
        let origin = clock.now
        return AutomationWaitTimeSource(
            nowMS: {
                let elapsed = origin.duration(to: clock.now).components
                return elapsed.seconds * 1_000 + Int64(elapsed.attoseconds / 1_000_000_000_000_000)
            },
            sleepMS: { milliseconds in
                try? await clock.sleep(for: .milliseconds(milliseconds))
            }
        )
    }
}

/// The bounded poll loop behind `POST /v1/wait`. Probes on the caller's isolation (the app
/// controller evaluates on the MainActor), sleeps between pending ticks, and never runs past
/// `plan.effectiveTimeoutMS` — the final sleep is truncated to the remaining budget, so a
/// timeout reports `waitedMS == effectiveTimeoutMS` rather than overshooting by a poll
/// interval. The ceiling exists because a wait executes between the listener's read deadline
/// (cancelled once the request parses) and write deadline (armed only after the route
/// returns): the wait itself is the bound, chosen below `AutomationSocketClient`'s default
/// receive deadline so a defaulted caller never times out client-side mid-wait.
public enum AutomationWaitEngine {
    public static func run(
        plan: AutomationWaitPlan,
        pollIntervalMS: Int = AutomationAPI.waitPollIntervalMS,
        timeSource: AutomationWaitTimeSource = .continuous(),
        probe: @MainActor @Sendable () async throws -> AutomationWaitProbe
    ) async rethrows -> AutomationWaitVerdict {
        let interval = max(1, pollIntervalMS)
        let startMS = timeSource.nowMS()
        while true {
            let tick = try await probe()
            let waitedMS = Int(timeSource.nowMS() - startMS)
            switch tick {
            case .satisfied(let observed):
                return AutomationWaitVerdict(outcome: .satisfied, waitedMS: waitedMS, observed: observed)
            case .notApplicable(let observed):
                return AutomationWaitVerdict(outcome: .notApplicable, waitedMS: waitedMS, observed: observed)
            case .pending(let observed):
                let remainingMS = plan.effectiveTimeoutMS - waitedMS
                guard remainingMS > 0 else {
                    return AutomationWaitVerdict(outcome: .timedOut, waitedMS: waitedMS, observed: observed)
                }
                await timeSource.sleepMS(Int64(min(interval, remainingMS)))
            }
        }
    }
}
