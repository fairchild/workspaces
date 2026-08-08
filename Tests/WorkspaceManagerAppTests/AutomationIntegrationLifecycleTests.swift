//
//  AutomationIntegrationLifecycleTests.swift
//  Verifies the App Intents operator gate: Shortcuts mint an operator handle only while the
//  operator experiment is on, and the gate is re-checked on every call — including the cached-
//  handle fast path.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationIntegrationLifecycle", .serialized)
struct AutomationIntegrationLifecycleTests {
    @Test("Shortcuts mint is gated on the operator experiment and re-checked per call")
    func appIntentMintGate() async throws {
        let lifecycle = AutomationIntegrationLifecycle.shared
        await lifecycle.configure(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        // Gate off: the Shortcuts path fails closed with a clear disabled error and mints nothing.
        do {
            _ = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: false)
            Issue.record("Expected the disabled operator experiment to fail closed.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
            #expect(error.response.message.contains("Automation Operator Scope"))
        }

        // Gate on: mints one operator handle and reuses it across calls.
        let first = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: true)
        #expect(lifecycle.handleRegistry.resolve(first.handle)?.isOperator == true)
        let second = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: true)
        #expect(second.handle == first.handle)

        // The gate runs before the cached-handle fast path: flipping the experiment off
        // mid-launch cuts Shortcuts off even though a handle is already minted.
        do {
            _ = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: false)
            Issue.record("Expected the re-checked gate to fail closed despite a cached handle.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }

        await lifecycle.stop()
    }
}
