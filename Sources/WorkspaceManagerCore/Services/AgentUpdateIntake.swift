import Foundation

/// Owns the host-side language and transport routing for Agent updates. The
/// concrete decoders remain below this Module; callers choose an intake purpose
/// instead of carrying legacy channel numbers or transport details.
public enum AgentUpdateIntake {
    public enum RegistryTarget: Sendable, Equatable {
        case agentSessionRegistry
        case lastCommandStatusRegistry
        case none
    }

    public enum Purpose: String, CaseIterable, Sendable, Equatable {
        case commandHookForwarder
        case statusLineForwarder
        case commandStatusProducer
        case terminalAttentionFallback
        case transcriptReader

        public var displayName: String {
            switch self {
            case .commandHookForwarder:
                "Command hook forwarder"
            case .statusLineForwarder:
                "Status-line forwarder"
            case .commandStatusProducer:
                "Command-status producer"
            case .terminalAttentionFallback:
                "libghostty OSC/BEL fallback"
            case .transcriptReader:
                "Transcript JSONL reader"
            }
        }

        public var registryTarget: RegistryTarget {
            switch self {
            case .commandHookForwarder, .statusLineForwarder, .terminalAttentionFallback:
                .agentSessionRegistry
            case .commandStatusProducer:
                .lastCommandStatusRegistry
            case .transcriptReader:
                .none
            }
        }
    }

    public enum HTTPRoute: Sendable, Equatable {
        case healthCheck
        case accepted(Purpose)

        public var purpose: Purpose? {
            switch self {
            case .healthCheck:
                nil
            case .accepted(let purpose):
                purpose
            }
        }

        public var responseBody: Data {
            switch self {
            case .healthCheck:
                Data("OK".utf8)
            case .accepted:
                Data()
            }
        }
    }

    public static func httpRoute(method: String, path: String) -> HTTPRoute? {
        switch (method.uppercased(), path) {
        case ("GET", "/healthz"):
            .healthCheck
        case ("POST", "/event"):
            .accepted(.commandHookForwarder)
        case ("POST", "/statusline"):
            .accepted(.statusLineForwarder)
        case ("POST", "/command-markers"):
            .accepted(.commandStatusProducer)
        default:
            nil
        }
    }

    public static func decodeHookEvent(from raw: Data) throws -> AgentEvent? {
        try ClaudeHookTranslator.decodeAgentEvent(from: raw)
    }

    public static func decodeStatusFields(from raw: Data) -> AgentEvent.StatusFields? {
        StatusLinePayload.decode(from: raw)?.toStatusFields()
    }

    public static func decodeCommandMarkers(from raw: Data) -> [CommandMarker] {
        CommandMarkerParser.parse(raw)
    }

    public static func terminalNotificationEvent(
        kind: AgentKind,
        title: String?,
        body: String
    ) -> AgentEvent {
        AgentOSCEventMapper.mapNotification(kind: kind, title: title, body: body)
    }

    public static func terminalBellEvent(kind: AgentKind) -> AgentEvent {
        AgentOSCEventMapper.mapBell(kind: kind)
    }
}
