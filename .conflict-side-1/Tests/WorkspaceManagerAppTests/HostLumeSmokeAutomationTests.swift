import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("HostLumeSmokeAutomation")
struct HostLumeSmokeAutomationTests {
    @Test("Configuration parses host smoke environment")
    func configurationParsesEnvironment() {
        let environment = [
            HostLumeSmokeAutomationConfiguration.modeEnvironmentKey: "host-lume-macos-smoke",
            HostLumeSmokeAutomationConfiguration.repoPathEnvironmentKey: "/tmp/repo",
            HostLumeSmokeAutomationConfiguration.workspaceNameEnvironmentKey: "smoke-v1",
            HostLumeSmokeAutomationConfiguration.eventsPathEnvironmentKey: "/tmp/events.jsonl",
        ]

        let configuration = HostLumeSmokeAutomationConfiguration.from(environment: environment)

        #expect(configuration?.repoURL.path == "/tmp/repo")
        #expect(configuration?.workspaceName == "smoke-v1")
        #expect(configuration?.eventsURL.path == "/tmp/events.jsonl")
    }

    @Test("Configuration requires all automation inputs")
    func configurationRequiresAllInputs() {
        let environment = [
            HostLumeSmokeAutomationConfiguration.modeEnvironmentKey: "host-lume-macos-smoke",
            HostLumeSmokeAutomationConfiguration.repoPathEnvironmentKey: "/tmp/repo",
        ]

        #expect(HostLumeSmokeAutomationConfiguration.from(environment: environment) == nil)
    }

    @Test("Workspace record decodes Lume metadata from creation result")
    func workspaceRecordDecodesLumeMetadata() throws {
        let metadata = LumeWorkspaceMetadata(
            vmName: "repo-smoke-1234",
            storagePath: "/tmp/lume-storage/workspace-vms",
            guestOS: .macOS,
            sharedHostPath: "/tmp/workspaces/repo/smoke-v1",
            desktopSupported: true,
            profileKey: "tahoe-26.2-xcode-26.2",
            profileDisplayName: "Tahoe 26.2 + Xcode 26.2",
            imageReference: "ghcr.io/workspaces/tahoe-26.2-xcode-26.2",
            baseVMName: "workspaces-validated-base-macos-tahoe-26-2-xcode-26-2",
            baseSourceKind: .pulledImage,
            launchLogPath: "/tmp/workspaces-lume-run-repo-smoke-1234.log"
        )
        let metadataRaw = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? ""

        let record = HostLumeSmokeWorkspaceRecord(
            result: WorkspaceProviderCreationResult(
                name: "smoke-v1",
                path: URL(fileURLWithPath: "/tmp/workspaces/repo/smoke-v1"),
                gitBranch: "workspace/smoke-v1",
                status: .provisioning,
                backendIdentifier: LumeWorkspaceProvider.identifier,
                remoteId: "repo-smoke-1234",
                backendMetadataRaw: metadataRaw
            )
        )

        #expect(record.workspaceName == "smoke-v1")
        #expect(record.remoteID == "repo-smoke-1234")
        #expect(record.lumeMetadata?.vmName == "repo-smoke-1234")
        #expect(record.lumeMetadata?.storagePath == "/tmp/lume-storage/workspace-vms")
        #expect(record.lumeMetadata?.profileDisplayName == "Tahoe 26.2 + Xcode 26.2")
        #expect(record.lumeMetadata?.baseVMName == "workspaces-validated-base-macos-tahoe-26-2-xcode-26-2")
        #expect(record.lumeMetadata?.baseSourceKind == "pulledImage")
        #expect(record.lumeMetadata?.launchLogPath == "/tmp/workspaces-lume-run-repo-smoke-1234.log")
    }

    @Test("Recovery hints point to VM runtime and logs for Lume failures")
    func recoveryHintsCoverLumeFailures() {
        #expect(
            hostLumeSmokeRecoveryHints(
                for: "Failed to create macOS VM workspace: Virtual machine not found"
            ) == ["Open VM Runtime", "Open Lume Log"]
        )
        #expect(hostLumeSmokeRecoveryHints(for: "A local workspace failed") == [])
    }
}
