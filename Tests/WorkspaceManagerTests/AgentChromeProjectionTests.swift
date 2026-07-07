import Testing

@testable import WorkspaceManagerCore

@Suite("AgentChromeProjection")
struct AgentChromeProjectionTests {
    @Test("Run states project labels tones severity and attention")
    func runStateProjectionMatrix() {
        let idle = AgentChromeProjection.runState(.idle)
        #expect(idle.diagnosticsLabel == "Idle")
        #expect(idle.summaryText == "Idle")
        #expect(idle.commandPaletteDescriptor == nil)
        #expect(idle.tone == .neutral)
        #expect(idle.sidebarPriority == 1)
        #expect(!idle.demandsAttention)

        let thinking = AgentChromeProjection.runState(.thinking)
        #expect(thinking.diagnosticsLabel == "Thinking")
        #expect(thinking.summaryText == "Thinking…")
        #expect(thinking.commandPaletteDescriptor == "thinking")
        #expect(thinking.tone == .running)
        #expect(thinking.sidebarPriority == 3)
        #expect(!thinking.demandsAttention)

        let running = AgentChromeProjection.runState(.runningTool(name: "Bash", detail: nil))
        #expect(running.diagnosticsLabel == "Running Bash")
        #expect(running.summaryText == "Running: Bash")
        #expect(running.commandPaletteDescriptor == "running tool")
        #expect(running.tone == .running)
        #expect(running.sidebarPriority == 3)
        #expect(!running.demandsAttention)

        let awaiting = AgentChromeProjection.runState(.awaitingInput(reason: .permissionPrompt))
        #expect(awaiting.diagnosticsLabel == "Awaiting permissionPrompt")
        #expect(awaiting.summaryText == "Awaiting input")
        #expect(awaiting.commandPaletteDescriptor == "awaiting input")
        #expect(awaiting.tone == .attention)
        #expect(awaiting.sidebarPriority == 4)
        #expect(awaiting.demandsAttention)

        let complete = AgentChromeProjection.runState(.complete)
        #expect(complete.diagnosticsLabel == "Complete")
        #expect(complete.summaryText == "Done")
        #expect(complete.commandPaletteDescriptor == nil)
        #expect(complete.tone == .neutral)
        #expect(complete.sidebarPriority == 1)
        #expect(!complete.demandsAttention)

        let errored = AgentChromeProjection.runState(.errored(category: .rateLimit, message: nil))
        #expect(errored.diagnosticsLabel == "Errored: rateLimit")
        #expect(errored.summaryText == "Rate limited")
        #expect(errored.commandPaletteDescriptor == "errored")
        #expect(errored.tone == .critical)
        #expect(errored.sidebarPriority == 5)
        #expect(errored.demandsAttention)
    }

    @Test("Permission prompt notification fires only on transition into permission prompt")
    func permissionPromptNotificationPolicy() {
        #expect(
            AgentChromeProjection.shouldPostPermissionPromptNotification(
                previous: nil,
                current: .awaitingInput(reason: .permissionPrompt)
            )
        )
        #expect(
            !AgentChromeProjection.shouldPostPermissionPromptNotification(
                previous: .awaitingInput(reason: .permissionPrompt),
                current: .awaitingInput(reason: .permissionPrompt)
            )
        )
        #expect(
            !AgentChromeProjection.shouldPostPermissionPromptNotification(
                previous: .thinking,
                current: .awaitingInput(reason: .idlePrompt)
            )
        )
        #expect(
            !AgentChromeProjection.shouldPostPermissionPromptNotification(
                previous: .thinking,
                current: .errored(category: .server, message: nil)
            )
        )
    }

    @Test("Attention tooltip fallback names attention states")
    func attentionTooltipFallback() {
        #expect(
            AgentChromeProjection.attentionTooltipFallback(count: 3)
                == "3 sessions awaiting input or errored"
        )
    }
}
