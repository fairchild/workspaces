//
//  CLIOperatorScopeDiagnosis.swift
//  WorkspaceManagerCore
//
//  Turns "operator credential not found" into the one action that fixes it. The old
//  message named the experiment, which is the wrong advice whenever health already
//  reports that experiment as on — the state a caller is most likely to be in, and
//  the one that reads as the CLI calling them a liar.
//

import Foundation

public enum CLIOperatorScopeDiagnosis {

    /// What the CLI could observe about the app before deciding what to say.
    public struct Observation: Sendable, Equatable {
        public let appIsRunning: Bool
        /// The health payload, or nil when the socket did not answer.
        public let server: AutomationServerDescriptor?

        public init(appIsRunning: Bool, server: AutomationServerDescriptor?) {
            self.appIsRunning = appIsRunning
            self.server = server
        }
    }

    /// The message a failed `loadOperatorCredential` raises. Always names the path,
    /// then exactly one next action chosen from what was observed.
    public static func message(credentialPath: String, observation: Observation) -> String {
        "Operator credential not found at \(credentialPath). \(advice(for: observation))"
    }

    static func advice(for observation: Observation) -> String {
        guard let server = observation.server else {
            return observation.appIsRunning
                ? """
                WorkSpaces is running but its automation socket did not answer, so the \
                Automation API experiment is probably off — enable it in WorkSpaces Settings \
                › Experimental, along with Automation Operator Scope.
                """
                : "WorkSpaces is not running. Open it and try again."
        }

        guard server.experiments.contains(ExperimentKey.operatorScope) else {
            return """
                The app is running with the Automation Operator Scope experiment off. Enable it \
                in WorkSpaces Settings › Experimental (or relaunch with \
                WORKSPACES_AUTOMATION_OPERATOR=1).
                """
        }

        switch server.operatorCredential {
        case .some(.minted), .some(.reused):
            return """
                The app reports a credential for this launch (pid \(server.pid)) that is not \
                readable here — another WorkSpaces launch quitting can remove it. Quit and \
                reopen WorkSpaces, then try again.
                """
        case .some(.mintFailed):
            return """
                The app is opted in but could not write the credential. Check that the \
                directory above is writable, then look for '[AutomationIntegration]' in \
                Console for the write error.
                """
        case .some(.notOptedIn):
            // The toggle read on and the provisioning pass read off, which can only mean the
            // two were sampled either side of a change.
            return """
                The app's last provisioning pass ran with operator scope off, though the \
                experiment reads on now. Quit and reopen WorkSpaces, then try again.
                """
        case .none:
            return """
                The experiment is on, but this app build (\(server.appVersion)) mints the \
                credential only while starting up, so turning the experiment on afterwards \
                does not take effect. Quit and reopen WorkSpaces, then try again.
                """
        }
    }

    /// The experiment's storage key, spelled once. `ExperimentalFeature` lives in the
    /// app target, which the CLI cannot import, and this string is what crosses the
    /// wire in the health payload's `experiments`.
    public enum ExperimentKey {
        public static let operatorScope = "automationOperator"
    }
}
