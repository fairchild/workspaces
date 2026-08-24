//
//  CLIOperatorScopeDiagnosisTests.swift
//  WorkspaceManagerTests
//
//  Each branch has to end in a different action, because the states behind a missing
//  credential need opposite responses — and the branch that used to be answered
//  wrongly (experiment on, credential never minted) is the common one.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLIOperatorScopeDiagnosis")
struct CLIOperatorScopeDiagnosisTests {

    private func server(
        experiments: [String] = ["automationAPI", "automationOperator"],
        operatorCredential: AutomationOperatorProvisioning.Outcome? = nil,
        appVersion: String = "0.24.0"
    ) -> AutomationServerDescriptor {
        AutomationServerDescriptor(
            pid: 5739,
            launchedAt: "2026-08-23T19:57:57Z",
            appVersion: appVersion,
            build: "release",
            experiments: experiments,
            operatorCredential: operatorCredential
        )
    }

    @Test("The message always names the path it looked at")
    func messageNamesThePath() {
        let message = CLIOperatorScopeDiagnosis.message(
            credentialPath: "/tmp/automation-operator.json",
            observation: .init(appIsRunning: false, server: nil)
        )
        #expect(message.hasPrefix("Operator credential not found at /tmp/automation-operator.json."))
    }

    @Test("No app, no socket: open the app")
    func appNotRunning() {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: false, server: nil)
        )
        #expect(advice == "WorkSpaces is not running. Open it and try again.")
    }

    @Test("App running but the socket is silent points at the Automation API experiment")
    func appRunningWithoutSocket() {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: true, server: nil)
        )
        #expect(advice.contains("did not answer"))
        #expect(advice.contains("Settings"))
    }

    @Test("Experiment genuinely off: enable it")
    func experimentOff() {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: true, server: server(experiments: ["automationAPI"]))
        )
        #expect(advice.contains("Operator Scope experiment off"))
        #expect(advice.contains("WORKSPACES_AUTOMATION_OPERATOR=1"))
    }

    /// The state this whole diagnosis exists for: health says the experiment is on, and
    /// the old message told the caller to turn on the thing health just said was on.
    @Test("Experiment on but the build cannot report provisioning: relaunch, and say why")
    func experimentOnWithUnreportingBuild() {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: true, server: server(operatorCredential: nil))
        )
        #expect(advice.contains("mints the credential only while starting up"))
        #expect(advice.contains("Quit and reopen WorkSpaces"))
        #expect(advice.contains("0.24.0"))
        // The advice a caller in this state must never be given again.
        #expect(!advice.contains("Enable it"))
    }

    @Test("A reported write failure sends the caller to the directory and the log, not to Settings")
    func mintFailure() {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: true, server: server(operatorCredential: .mintFailed))
        )
        #expect(advice.contains("could not write the credential"))
        #expect(advice.contains("[AutomationIntegration]"))
        #expect(!advice.contains("Settings"))
    }

    @Test(
        "A credential the app believes in but the CLI cannot read reads as removal",
        arguments: [
            AutomationOperatorProvisioning.Outcome.minted,
            AutomationOperatorProvisioning.Outcome.reused,
        ]
    )
    func credentialReportedButUnreadable(outcome: AutomationOperatorProvisioning.Outcome) {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: true, server: server(operatorCredential: outcome))
        )
        #expect(advice.contains("another WorkSpaces launch quitting can remove it"))
        #expect(advice.contains("pid 5739"))
    }

    @Test("A provisioning pass that ran with opt-in off, against an experiment now on, reads as a relaunch")
    func provisioningRanBeforeOptIn() {
        let advice = CLIOperatorScopeDiagnosis.advice(
            for: .init(appIsRunning: true, server: server(operatorCredential: .notOptedIn))
        )
        #expect(advice.contains("last provisioning pass ran with operator scope off"))
        #expect(advice.contains("Quit and reopen WorkSpaces"))
    }

    @Test("Every branch ends in exactly one action")
    func everyBranchNamesOneAction() {
        let observations: [CLIOperatorScopeDiagnosis.Observation] = [
            .init(appIsRunning: false, server: nil),
            .init(appIsRunning: true, server: nil),
            .init(appIsRunning: true, server: server(experiments: ["automationAPI"])),
            .init(appIsRunning: true, server: server(operatorCredential: nil)),
            .init(appIsRunning: true, server: server(operatorCredential: .minted)),
            .init(appIsRunning: true, server: server(operatorCredential: .mintFailed)),
            .init(appIsRunning: true, server: server(operatorCredential: .notOptedIn)),
        ]
        var seen = Set<String>()
        for observation in observations {
            let advice = CLIOperatorScopeDiagnosis.advice(for: observation)
            #expect(!advice.isEmpty)
            // Distinct states must not collapse onto one message, or the diagnosis is
            // decoration rather than a diagnosis.
            #expect(seen.insert(advice).inserted)
        }
    }
}
