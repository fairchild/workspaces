import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("AgentUpdateIntake")
struct AgentUpdateIntakeTests {
    @Test("HTTP routes map to named intake purposes")
    func httpRoutesMapToPurposes() {
        #expect(AgentUpdateIntake.httpRoute(method: "GET", path: "/healthz") == .healthCheck)
        #expect(
            AgentUpdateIntake.httpRoute(method: "POST", path: "/event")?.purpose
                == .commandHookForwarder
        )
        #expect(
            AgentUpdateIntake.httpRoute(method: "POST", path: "/statusline")?.purpose
                == .statusLineForwarder
        )
        #expect(
            AgentUpdateIntake.httpRoute(method: "POST", path: "/command-markers")?.purpose
                == .commandStatusProducer
        )
        #expect(AgentUpdateIntake.httpRoute(method: "POST", path: "/unknown") == nil)
    }

    @Test("Intake purposes declare registry targets")
    func purposesDeclareRegistryTargets() {
        #expect(
            AgentUpdateIntake.Purpose.commandHookForwarder.registryTarget
                == .agentSessionRegistry
        )
        #expect(
            AgentUpdateIntake.Purpose.statusLineForwarder.registryTarget
                == .agentSessionRegistry
        )
        #expect(
            AgentUpdateIntake.Purpose.terminalAttentionFallback.registryTarget
                == .agentSessionRegistry
        )
        #expect(
            AgentUpdateIntake.Purpose.commandStatusProducer.registryTarget
                == .lastCommandStatusRegistry
        )
        #expect(AgentUpdateIntake.Purpose.transcriptReader.registryTarget == .none)
    }

    @Test("Terminal attention notification maps through intake module")
    func terminalAttentionNotificationMapsThroughIntakeModule() {
        let event = AgentUpdateIntake.terminalNotificationEvent(
            kind: .claudeCode,
            title: "Permission",
            body: "Tool needs permission"
        )

        if case .awaitingInput(.permissionPrompt, "Permission"?, "Tool needs permission"?) = event {
            // ok
        } else {
            Issue.record("expected permission prompt event, got \(event)")
        }
    }
}
