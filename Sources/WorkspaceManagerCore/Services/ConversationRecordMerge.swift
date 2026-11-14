//
//  ConversationRecordMerge.swift
//  WorkspaceManagerCore
//
//  The one merge every Conversation record writer goes through. Writers run in different
//  processes and their observations land in any order, so the merge is built so that a set
//  of observations makes the same record whatever order it arrives in.
//

import Foundation

extension ConversationRecordJSON {
    /// When each field's value was observed, keyed by field (`launch.handle` for nested ones).
    static let fieldObservedAtKey = "fieldObservedAt"
    /// The location sightings still consistent with the newest one, newest first.
    static let sightingsKey = "sightings"
    /// The newest sighting that contradicted them. Anything not newer than it is history.
    static let sightingsAfterKey = "sightingsAfter"
    /// The processes named as running the conversation, kept apart from the sightings.
    static let harnessProcessesKey = "harnessProcesses"

    /// Applies `observation` to the file's object.
    ///
    /// The property: merging a set of observations gives the same object whatever order they
    /// arrive in, and merging one twice changes nothing. Every fact keeps the time of the
    /// observation that set it, rather than the record keeping one time for all of them:
    /// - A field (`cwd`, `transcriptPath`, `launch.model`, …) takes the value of the newest
    ///   observation that carried one; a tie on time goes to the larger value. An observation
    ///   that does not carry a field leaves it alone, so unknown never erases known.
    /// - `observedAt` is the newest observation's time and `createdAt` the earliest.
    /// - Location is a holder (`hostSessionID`) and a tmux fact (a session's `serverPID` and
    ///   `sessionID`, or `outsideTmux`). A part an observation does not state is unknown, never
    ///   "none": no writer can see that no tile holds a conversation. Sightings are kept
    ///   newest first for as long as their known parts agree. The first that contradicts them
    ///   ends the run, and it and everything older become history. So a sighting that
    ///   matches the current place fills it in or refreshes it whatever its age, and one that
    ///   contradicts it moves the conversation only if it is newer than every sighting of the
    ///   current place. `lastSeenIn` is that run read as one place, with each tmux attribute
    ///   from the newest sighting that had it.
    /// - A process named as running the conversation joins `harnessProcesses` and stays, with
    ///   the newest time and place it was named, until `ended` says it has exited. The
    ///   chain of processes a hook that found no claude above it ran under joins `unattributed`
    ///   and stays until every one of them has exited. A writer on another host than the
    ///   record's removes none.
    ///
    /// Keys this build does not know survive at the top level, under `launch`, and in each
    /// kept sighting. `lastSeenIn` is rewritten from the sightings on every merge, so a build
    /// that records a new location fact adds it to the sightings.
    static func merge(
        _ observation: ConversationObservation,
        into existing: [String: Any]?,
        ended: (ProcessIdentity) -> Bool = { _ in false }
    ) -> [String: Any] {
        var object = existing ?? [:]
        // Read before any field or time below moves: a record from before sightings is seeded
        // from its own `observedAt`, not this observation's.
        var location = LocationHistory(object: object)
        let at = date(string(observation.observedAt)) ?? observation.observedAt
        var observed = object[fieldObservedAtKey] as? [String: Any] ?? legacyFieldTimes(object)

        func register(_ key: String, _ value: Any?, in target: inout [String: Any], as field: String? = nil) {
            guard let value else { return }
            let field = field ?? key
            if let current = target[key], let currentAt = date(observed[field]),
                (at, "\(value)") <= (currentAt, "\(current)")
            {
                return
            }
            target[key] = value
            observed[field] = string(at)
        }

        let recordedAt = date(object["observedAt"])
        let recordedHost = object["host"] as? String
        object["schema"] = max(object["schema"] as? Int ?? 0, ConversationRecord.schemaVersion)
        object["conversationID"] = observation.conversationID
        register("harness", observation.harness, in: &object)
        register("host", observation.host, in: &object)
        register("cwd", observation.cwd, in: &object)
        register("configHome", observation.configHome, in: &object)
        register("transcriptPath", observation.transcriptPath, in: &object)
        register("workspacePath", observation.workspacePath, in: &object)
        register("workspaceCreatedAt", observation.workspaceCreatedAt.map(string), in: &object)
        register("socketLabel", observation.socketLabel, in: &object)
        register("observedBy", observation.observedBy.rawValue, in: &object)
        if let launch = observation.launch {
            var target = object["launch"] as? [String: Any] ?? [:]
            register("handle", launch.handle, in: &target, as: "launch.handle")
            register("model", launch.model, in: &target, as: "launch.model")
            register("effort", launch.effort, in: &target, as: "launch.effort")
            object["launch"] = target
        }
        object[fieldObservedAtKey] = observed
        object["createdAt"] = string([date(object["createdAt"]) ?? at, at].min() ?? at)
        object["observedAt"] = string(max(recordedAt ?? at, at))

        if let seen = observation.lastSeenIn, let sighting = Sighting(seen, at: at) {
            location.insert(sighting)
        }
        location.write(into: &object)
        // The writer's kernel knows nothing of processes on the machine the record came from.
        let local = recordedHost == nil || recordedHost == observation.host
        mergeHarness(
            observation.harnessProcess, seenIn: observation.lastSeenIn, at: at, into: &object,
            ended: local ? ended : { _ in false })
        return object
    }

    private static func mergeHarness(
        _ answer: ConversationRecord.HarnessAnswer?,
        seenIn: ConversationRecord.LastSeenIn?,
        at: Date,
        into object: inout [String: Any],
        ended: (ProcessIdentity) -> Bool
    ) {
        // Ownership the reader would call damaged is left exactly as it is, and nothing in it is
        // pruned: rewriting it would forget whoever it names.
        guard harnessProcesses(from: object[harnessProcessesKey]) != nil,
            var processes = object[harnessProcessesKey].map({ $0 as? [String: Any] }) ?? [:],
            var entries = processes["entries"].map({ $0 as? [[String: Any]] }) ?? [],
            var unattributed = processes["unattributed"].map({ $0 as? [[String: Any]] }) ?? []
        else { return }
        func addChain(_ chain: [ProcessIdentity]) {
            guard !chain.isEmpty else { return }
            var entry: [String: Any] = ["chain": chain.map(\.recorded), "observedAt": string(at)]
            entry["seenIn"] = seenIn.map(object(from:))
            upsert(entry, at: at, key: chainKey, into: &unattributed)
        }
        switch answer {
        case .named(let process, let passing)?:
            var entry: [String: Any] = ["process": process.recorded, "observedAt": string(at)]
            entry["seenIn"] = seenIn.map(object(from:))
            upsert(entry, at: at, key: namedKey, into: &entries)
            addChain(passing)
        case .unnamed(let chain)?:
            addChain(chain)
        case nil:
            break
        }
        entries.removeAll { entry in
            (entry["process"] as? String).flatMap(ProcessIdentity.init(recorded:)).map(ended) ?? false
        }
        // A chain keeps only its members that may still run, so repeated hooks from one shell
        // come down to one entry; one it cannot read is kept whole.
        var living: [[String: Any]] = []
        for var entry in unattributed {
            if let chain = entry["chain"] as? [String] {
                let identities = chain.compactMap(ProcessIdentity.init(recorded:))
                if identities.count == chain.count {
                    let remaining = identities.filter { !ended($0) }
                    guard !remaining.isEmpty else { continue }
                    entry["chain"] = remaining.map(\.recorded)
                }
            }
            guard let observedAt = date(entry["observedAt"]) else {
                living.append(entry)
                continue
            }
            upsert(entry, at: observedAt, key: chainKey, into: &living)
        }
        unattributed = living
        entries.sort { (namedKey($0) ?? "") < (namedKey($1) ?? "") }
        unattributed.sort { (chainKey($0) ?? "") < (chainKey($1) ?? "") }
        processes["entries"] = entries.isEmpty ? nil : entries
        processes["unattributed"] = unattributed.isEmpty ? nil : unattributed
        object[harnessProcessesKey] = processes.isEmpty ? nil : processes
    }

    private static func namedKey(_ entry: [String: Any]) -> String? { entry["process"] as? String }

    private static func chainKey(_ entry: [String: Any]) -> String? {
        (entry["chain"] as? [String])?.joined(separator: " ")
    }

    /// One entry per key, keeping the newest time and place it was seen at.
    private static func upsert(
        _ entry: [String: Any], at: Date, key: ([String: Any]) -> String?, into list: inout [[String: Any]]
    ) {
        guard let index = list.firstIndex(where: { key($0) != nil && key($0) == key(entry) }) else {
            list.append(entry)
            return
        }
        if (at, canonical(entry)) > (date(list[index]["observedAt"]) ?? .distantPast, canonical(list[index])) {
            list[index] = entry
        }
    }

    /// One spelling of an object, so a tie on time goes the same way whatever order the
    /// observations came in.
    private static func canonical(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A record written before fields carried their own times: each present field counts as
    /// seen when the record was.
    private static func legacyFieldTimes(_ object: [String: Any]) -> [String: Any] {
        guard let recordedAt = object["observedAt"] as? String else { return [:] }
        var observed: [String: Any] = [:]
        for key in [
            "harness", "host", "cwd", "configHome", "transcriptPath", "workspacePath", "workspaceCreatedAt",
            "socketLabel", "observedBy",
        ] where object[key] != nil {
            observed[key] = recordedAt
        }
        for key in ["handle", "model", "effort"] where (object["launch"] as? [String: Any])?[key] != nil {
            observed["launch.\(key)"] = recordedAt
        }
        return observed
    }
}

// MARK: - Location

/// What one sighting says about tmux.
enum TmuxFact: Equatable {
    case unknown
    case outside
    case session(serverPID: Int, sessionID: String)

    var key: String {
        switch self {
        case .unknown: ""
        case .outside: "outside"
        case .session(let pid, let id): "\(pid):\(id)"
        }
    }

    func contradicts(_ other: TmuxFact) -> Bool {
        self != .unknown && other != .unknown && self != other
    }
}

/// One place a conversation was seen, with the newest time it was seen there. Sightings
/// with the same known parts share one entry; its tmux attributes keep their own times.
struct Sighting {
    var holder: String?
    var tmux: TmuxFact
    var at: Date
    var object: [String: Any]

    var key: String { "\(holder ?? "")|\(tmux.key)" }
    var order: (Date, String) { (at, key) }

    init?(_ seen: ConversationRecord.LastSeenIn, at: Date) {
        holder = seen.hostSessionID
        var object: [String: Any] = ["observedAt": ConversationRecordJSON.string(at)]
        if let holder { object["hostSessionID"] = holder }
        if let tmux = seen.tmux {
            self.tmux = .session(serverPID: tmux.serverPID, sessionID: tmux.sessionID)
            var session: [String: Any] = ["serverPID": tmux.serverPID, "sessionID": tmux.sessionID]
            let attributes: [(String, Any?)] = [
                ("createdAt", tmux.createdAt.map(ConversationRecordJSON.string)), ("name", tmux.name),
                ("socketPath", tmux.socketPath), ("serverStartedAt", tmux.serverStartedAtMicroseconds),
            ]
            for case (let attribute, let value?) in attributes {
                session[attribute] = value
                session["\(attribute)ObservedAt"] = object["observedAt"]
            }
            object["tmux"] = session
        } else if seen.outsideTmux {
            self.tmux = .outside
            object["outsideTmux"] = true
        } else {
            self.tmux = .unknown
        }
        guard holder != nil || self.tmux != .unknown else { return nil }
        self.at = at
        self.object = object
    }

    /// Attributes of the tmux session, each with the time it was observed.
    static let tmuxAttributes = ["createdAt", "name", "socketPath", "serverStartedAt"]

    init?(object: [String: Any]) {
        guard let at = ConversationRecordJSON.date(object["observedAt"]) else { return nil }
        holder = object["hostSessionID"] as? String
        if let session = object["tmux"] as? [String: Any],
            let pid = session["serverPID"] as? Int,
            let id = session["sessionID"] as? String
        {
            tmux = .session(serverPID: pid, sessionID: id)
        } else {
            tmux = object["outsideTmux"] as? Bool == true ? .outside : .unknown
        }
        guard holder != nil || tmux != .unknown else { return nil }
        self.at = at
        self.object = object
    }

    func agrees(holder otherHolder: String?, tmux otherTmux: TmuxFact) -> Bool {
        !(holder != nil && otherHolder != nil && holder != otherHolder) && !tmux.contradicts(otherTmux)
    }

    /// Folds another sighting with the same known parts into this one.
    mutating func absorb(_ other: Sighting) {
        if other.at > at {
            at = other.at
            object["observedAt"] = other.object["observedAt"]
        }
        guard var session = object["tmux"] as? [String: Any], let theirs = other.object["tmux"] as? [String: Any]
        else { return }
        for attribute in Self.tmuxAttributes {
            Self.takeNewer(attribute, from: theirs, into: &session)
        }
        object["tmux"] = session
    }

    /// Drops tmux attributes observed at or before `cut`. A sighting that absorbed a newer
    /// one keeps that one's time, but its attributes keep their own; once the cut passes
    /// them they are history like any other observation that old, whatever order it came in.
    mutating func forget(atOrBefore cut: (Date, String)) {
        guard var session = object["tmux"] as? [String: Any] else { return }
        Self.forget(Self.tmuxAttributes, in: &session, atOrBefore: cut, key: key)
        object["tmux"] = session
    }

    private static func forget(
        _ attributes: [String],
        in target: inout [String: Any],
        atOrBefore cut: (Date, String),
        key: String
    ) {
        for attribute in attributes {
            let stamp = "\(attribute)ObservedAt"
            if let observed = ConversationRecordJSON.date(target[stamp]), (observed, key) <= cut {
                target[attribute] = nil
                target[stamp] = nil
            }
        }
    }

    /// The attribute from whichever side observed it later; a tie goes to the larger value.
    static func takeNewer(_ attribute: String, from source: [String: Any], into target: inout [String: Any]) {
        let stamp = "\(attribute)ObservedAt"
        guard let value = source[attribute], let at = ConversationRecordJSON.date(source[stamp]) else { return }
        if let current = target[attribute], let currentAt = ConversationRecordJSON.date(target[stamp]),
            (at, "\(value)") <= (currentAt, "\(current)")
        {
            return
        }
        target[attribute] = value
        target[stamp] = source[stamp]
    }
}

/// The run of sightings that agree with the newest one, and where that run begins.
struct LocationHistory {
    private var sightings: [Sighting]
    private var after: (Date, String)?

    init(object: [String: Any]) {
        let stored = (object[ConversationRecordJSON.sightingsKey] as? [[String: Any]])?
            .compactMap(Sighting.init(object:))
        if let stored {
            sightings = stored
        } else if let at = ConversationRecordJSON.date(object["observedAt"]),
            let legacy = (object["lastSeenIn"] as? [String: Any]).map(ConversationRecordJSON.lastSeenIn(from:)),
            let sighting = Sighting(legacy, at: at)
        {
            // A record from before sightings: its one place, seen when the record was.
            sightings = [sighting]
        } else {
            sightings = []
        }
        if let boundary = object[ConversationRecordJSON.sightingsAfterKey] as? [String: Any],
            let at = ConversationRecordJSON.date(boundary["observedAt"])
        {
            after = (at, boundary["key"] as? String ?? "")
        }
    }

    mutating func insert(_ sighting: Sighting) {
        if let after, sighting.order <= after { return }
        if let index = sightings.firstIndex(where: { $0.key == sighting.key }) {
            sightings[index].absorb(sighting)
        } else {
            sightings.append(sighting)
        }
        sightings.sort { $0.order > $1.order }
        var holder: String?
        var tmux = TmuxFact.unknown
        for (index, candidate) in sightings.enumerated() {
            guard candidate.agrees(holder: holder, tmux: tmux) else {
                after = candidate.order
                sightings.removeSubrange(index...)
                for kept in sightings.indices {
                    sightings[kept].forget(atOrBefore: candidate.order)
                }
                return
            }
            holder = holder ?? candidate.holder
            if tmux == .unknown { tmux = candidate.tmux }
        }
    }

    func write(into object: inout [String: Any]) {
        guard !sightings.isEmpty else { return }
        object[ConversationRecordJSON.sightingsKey] = sightings.map(\.object)
        if let after {
            object[ConversationRecordJSON.sightingsAfterKey] = [
                "observedAt": ConversationRecordJSON.string(after.0), "key": after.1,
            ]
        }
        object["lastSeenIn"] = place()
    }

    /// The run read as one place.
    private func place() -> [String: Any] {
        var place: [String: Any] = [:]
        if let holder = sightings.lazy.compactMap(\.holder).first { place["hostSessionID"] = holder }
        if let session = sightings.first(where: { if case .session = $0.tmux { true } else { false } }) {
            var merged: [String: Any] = [:]
            for sighting in sightings where sighting.tmux == session.tmux {
                guard let theirs = sighting.object["tmux"] as? [String: Any] else { continue }
                for attribute in Sighting.tmuxAttributes {
                    Sighting.takeNewer(attribute, from: theirs, into: &merged)
                }
            }
            var tmux: [String: Any] = [:]
            if case .session(let pid, let id) = session.tmux {
                tmux["serverPID"] = pid
                tmux["sessionID"] = id
            }
            for attribute in Sighting.tmuxAttributes {
                tmux[attribute] = merged[attribute]
            }
            place["tmux"] = tmux
        } else if sightings.contains(where: { $0.tmux == .outside }) {
            place["outsideTmux"] = true
        }
        return place
    }
}
