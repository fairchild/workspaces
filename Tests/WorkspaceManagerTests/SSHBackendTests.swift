import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("SSHBackend")
struct SSHBackendTests {
    @Test("Generates SSH login-shell command for plain SSH workspaces")
    func generatesPlainSSHCommand() throws {
        let request = makeRequest(
            ssh: SSHWorkspaceMetadata(
                host: "ssh.example.com",
                user: "alice",
                port: 2222,
                authMode: "ssh-agent",
                workingDir: "/srv/workspaces/feature-a"
            )
        )

        let plan = try SSHBackend.sessionPlan(for: request, sshExecutable: "/usr/bin/ssh")
        let bootstrapScript = try #require(plan.bootstrapArguments.last)

        #expect(plan.remoteId == "remote-123")
        #expect(plan.workingDirectory == "/srv/workspaces/feature-a")
        #expect(plan.bootstrapArguments.contains("alice@ssh.example.com"))
        #expect(bootstrapScript.contains("/srv/workspaces/feature-a"))
        #expect(plan.interactiveCommand.contains("/usr/bin/ssh"))
        #expect(plan.interactiveCommand.contains("alice@ssh.example.com"))
        #expect(plan.interactiveCommand.contains("/srv/workspaces/feature-a"))
        #expect(plan.interactiveCommand.contains("exec ${SHELL:-/bin/bash} -l"))
        assertTTYFlagPrecedesDestination(
            in: plan.interactiveCommand,
            destination: "alice@ssh.example.com"
        )
    }

    @Test("Resolves default working directory from sanitized repo and workspace names")
    func resolvesDefaultWorkingDirectory() {
        let request = RemoteWorkspaceSessionRequest(
            workspaceID: UUID(),
            name: "Feature/A",
            backendIdentifier: SSHBackend.identifier,
            remoteId: "remote-123",
            status: .active,
            repoName: "Acme API",
            repoRemoteURL: "git@github.com:acme/api.git",
            sshMetadata: SSHWorkspaceMetadata(host: "ssh.example.com"),
            composeMetadata: nil
        )

        let resolved = SSHBackend.resolvedWorkingDirectory(
            for: request,
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        #expect(resolved == "~/workspaces/acme-api/feature-a")
    }

    @Test("Default home-relative working directory expands with HOME in shell scripts")
    func defaultWorkingDirectoryExpandsHomeDirectory() throws {
        let request = makeRequest(
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        let plan = try SSHBackend.sessionPlan(for: request)
        let bootstrapScript = try #require(plan.bootstrapArguments.last)
        let workingDirectorySuffix = "/workspaces/api/feature-a"

        #expect(bootstrapScript.contains("mkdir -p $HOME"))
        #expect(bootstrapScript.contains(workingDirectorySuffix))
        #expect(bootstrapScript.contains(".git"))
        #expect(plan.interactiveCommand.contains("$HOME"))
        #expect(plan.interactiveCommand.contains(workingDirectorySuffix))
        #expect(!bootstrapScript.contains("~/workspaces"))
        #expect(!plan.interactiveCommand.contains("~/workspaces"))
    }

    @Test("Bootstrap script clones when the remote checkout is missing")
    func bootstrapScriptClonesWhenMissing() throws {
        let request = makeRequest(
            ssh: SSHWorkspaceMetadata(
                host: "ssh.example.com",
                workingDir: "/srv/workspaces/feature-a"
            )
        )

        let plan = try SSHBackend.sessionPlan(for: request)
        let script = try #require(plan.bootstrapArguments.last)

        #expect(script.contains("if [ ! -d "))
        #expect(script.contains("/srv/workspaces/feature-a/.git"))
        #expect(script.contains("git clone"))
        #expect(script.contains("git@github.com:acme/api.git"))
        #expect(script.contains("/srv/workspaces/feature-a"))
    }

    @Test("Missing repository remote URL fails before opening the session")
    func missingRepositoryRemoteURLFails() {
        let request = makeRequest(
            repoRemoteURL: nil,
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        do {
            _ = try SSHBackend.sessionPlan(for: request)
            Issue.record("Expected missing remote URL to fail session planning")
        } catch let error as RemoteWorkspaceError {
            #expect(error.localizedDescription == RemoteWorkspaceError.missingRemoteURL.localizedDescription)
        } catch {
            Issue.record("Expected RemoteWorkspaceError.missingRemoteURL, got \(error)")
        }
    }

    @Test("Invalid SSH port fails before opening the session")
    func invalidSSHPortFails() {
        let request = makeRequest(
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com", port: 0)
        )

        do {
            _ = try SSHBackend.sessionPlan(for: request)
            Issue.record("Expected invalid SSH port to fail session planning")
        } catch let error as RemoteWorkspaceError {
            #expect(
                error.localizedDescription.contains("port must be between 1 and 65535")
            )
        } catch {
            Issue.record("Expected RemoteWorkspaceError.invalidSSHConfiguration, got \(error)")
        }
    }

    @Test("Compose workspaces include config, up, and exec commands")
    func composeCommandsAreIncluded() throws {
        let request = makeRequest(
            ssh: SSHWorkspaceMetadata(
                host: "ssh.example.com",
                workingDir: "/srv/workspaces/feature-a"
            ),
            compose: ComposeWorkspaceMetadata(
                projectName: "acme",
                composeFiles: ["compose.yml", "compose.dev.yml"],
                service: "web"
            )
        )

        let plan = try SSHBackend.sessionPlan(for: request)
        let bootstrapScript = try #require(plan.bootstrapArguments.last)

        #expect(bootstrapScript.contains("docker compose -p acme -f compose.yml -f compose.dev.yml config >/dev/null"))
        #expect(bootstrapScript.contains("docker compose -p acme -f compose.yml -f compose.dev.yml up -d"))
        #expect(plan.interactiveCommand.contains("docker compose -p acme -f compose.yml -f compose.dev.yml exec"))
        #expect(plan.interactiveCommand.contains("web"))
        #expect(plan.interactiveCommand.contains("${SHELL:-/bin/bash} -l"))
    }

    @Test("Bootstrap failures surface before a terminal command is returned")
    func bootstrapFailuresSurface() async throws {
        let backend = SSHBackend(
            runCommand: { _, _ in
                ProcessResult(exitCode: 1, stdout: "", stderr: "clone failed")
            },
            resolveExecutablePath: { _ in "/usr/bin/ssh" }
        )
        let request = makeRequest(
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        do {
            _ = try await backend.openSession(for: request)
            Issue.record("Expected SSH bootstrap failure to throw")
        } catch {
            #expect(error is RemoteWorkspaceError)
            #expect(error.localizedDescription.contains("clone failed"))
        }
    }

    private func makeRequest(
        repoRemoteURL: String? = "git@github.com:acme/api.git",
        ssh: SSHWorkspaceMetadata,
        compose: ComposeWorkspaceMetadata? = nil
    ) -> RemoteWorkspaceSessionRequest {
        let repo = Repo(
            name: "api",
            localPath: URL(fileURLWithPath: "/tmp/api"),
            remoteURL: repoRemoteURL
        )
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/api/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: SSHBackend.identifier,
            remoteId: "remote-123"
        )
        workspace.sshMetadata = ssh
        workspace.composeMetadata = compose
        return workspace.remoteSessionRequest
    }

    private func assertTTYFlagPrecedesDestination(
        in interactiveCommand: String,
        destination: String
    ) {
        let ttyRange = interactiveCommand.range(of: " -t ")
        let destinationRange = interactiveCommand.range(of: destination)

        #expect(ttyRange != nil)
        #expect(destinationRange != nil)
        if let ttyRange, let destinationRange {
            #expect(ttyRange.lowerBound < destinationRange.lowerBound)
        }
    }
}
