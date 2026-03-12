import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("SSHBackend")
struct SSHBackendTests {
    @Test("Generates SSH login-shell command for plain SSH workspaces")
    func generatesPlainSSHCommand() throws {
        let workspace = makeWorkspace(
            ssh: SSHWorkspaceMetadata(
                host: "ssh.example.com",
                user: "alice",
                port: 2222,
                authMode: "ssh-agent",
                workingDir: "/srv/workspaces/feature-a"
            )
        )

        let plan = try SSHBackend.sessionPlan(for: workspace, sshExecutable: "/usr/bin/ssh")
        let bootstrapScript = try #require(plan.bootstrapArguments.last)

        #expect(plan.remoteId == "remote-123")
        #expect(plan.workingDirectory == "/srv/workspaces/feature-a")
        #expect(plan.bootstrapArguments.contains("alice@ssh.example.com"))
        #expect(bootstrapScript.contains("/srv/workspaces/feature-a"))
        #expect(plan.interactiveCommand.contains("/usr/bin/ssh"))
        #expect(plan.interactiveCommand.contains("alice@ssh.example.com"))
        #expect(plan.interactiveCommand.contains("/srv/workspaces/feature-a"))
        #expect(plan.interactiveCommand.contains("exec ${SHELL:-/bin/bash} -l"))
    }

    @Test("Resolves default working directory from repo and workspace names")
    func resolvesDefaultWorkingDirectory() {
        let repo = Repo(name: "acme-api", localPath: URL(fileURLWithPath: "/tmp/acme"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/acme/workspaces/feature-a"),
            sourceRepo: repo,
            backendIdentifier: SSHBackend.identifier,
            remoteId: "remote-123"
        )

        let resolved = SSHBackend.resolvedWorkingDirectory(
            for: workspace,
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        #expect(resolved == "~/workspaces/acme-api/feature-a")
    }

    @Test("Bootstrap script clones when the remote checkout is missing")
    func bootstrapScriptClonesWhenMissing() throws {
        let workspace = makeWorkspace(
            ssh: SSHWorkspaceMetadata(
                host: "ssh.example.com",
                workingDir: "/srv/workspaces/feature-a"
            )
        )

        let plan = try SSHBackend.sessionPlan(for: workspace)
        let script = try #require(plan.bootstrapArguments.last)

        #expect(script.contains("if [ ! -d '/srv/workspaces/feature-a/.git' ]; then git clone"))
        #expect(script.contains("'git@github.com:acme/api.git' '/srv/workspaces/feature-a'"))
    }

    @Test("Missing repository remote URL fails before opening the session")
    func missingRepositoryRemoteURLFails() async throws {
        let workspace = makeWorkspace(
            repoRemoteURL: nil,
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        await #expect(throws: RemoteWorkspaceError.self) {
            _ = try await SSHBackend().openSession(for: workspace)
        }
    }

    @Test("Compose workspaces include config, up, and exec commands")
    func composeCommandsAreIncluded() throws {
        let workspace = makeWorkspace(
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

        let plan = try SSHBackend.sessionPlan(for: workspace)
        let bootstrapScript = try #require(plan.bootstrapArguments.last)

        #expect(bootstrapScript.contains("docker compose -p acme -f compose.yml -f compose.dev.yml config >/dev/null"))
        #expect(bootstrapScript.contains("docker compose -p acme -f compose.yml -f compose.dev.yml up -d"))
        #expect(plan.interactiveCommand.contains("docker compose -p acme -f compose.yml -f compose.dev.yml exec"))
        #expect(plan.interactiveCommand.contains("web"))
        #expect(plan.interactiveCommand.contains("${SHELL:-/bin/bash} -l"))
    }

    @Test("Bootstrap failures surface before a terminal command is returned")
    func bootstrapFailuresSurface() async throws {
        let backend = SSHBackend { _, _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "clone failed")
        }
        let workspace = makeWorkspace(
            ssh: SSHWorkspaceMetadata(host: "ssh.example.com")
        )

        do {
            _ = try await backend.openSession(for: workspace)
            Issue.record("Expected SSH bootstrap failure to throw")
        } catch {
            #expect(error is RemoteWorkspaceError)
            #expect(error.localizedDescription.contains("clone failed"))
        }
    }

    private func makeWorkspace(
        repoRemoteURL: String? = "git@github.com:acme/api.git",
        ssh: SSHWorkspaceMetadata,
        compose: ComposeWorkspaceMetadata? = nil
    ) -> Workspace {
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
        return workspace
    }
}
