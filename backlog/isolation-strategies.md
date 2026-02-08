# Workspace Isolation Strategies

**TL;DR**: Apple just shipped a native Swift containerization framework (WWDC 2025) that's perfect for this use case. For MVP, abstract behind a protocol and start with the simplest option (local directory), then add Apple Container, Docker, and remote VMs as backends.

---

## The Options at a Glance

| Strategy | Isolation Level | Startup | Overhead | Requirements | Best For |
|---

> **GitHub Issue**: https://github.com/fairchild/workspaces/issues/1
-------|-----------------|---------|----------|--------------|----------|
| **Local Directory** | None | Instant | Zero | None | MVP, trust user |
| **Apple Container** | VM-per-container | ~300ms | Low | macOS 26+, Apple Silicon | Production on Mac |
| **Docker** | Shared kernel | ~1-2s | Medium | Docker Desktop | Cross-platform |
| **Apple Virtualization** | Full VM | ~5-10s | High | macOS 12+ | Complete isolation |
| **Remote VM** (Fly.io, EC2) | Full VM | ~30-60s | Network latency | Internet, API keys | Untrusted code, GPUs |

---

## 1. Apple Containerization Framework (Recommended for Mac-native)

**What it is**: Apple's WWDC 2025 announcement—a native Swift framework for running Linux containers, each in its own lightweight VM. Unlike Docker (shared kernel), each container gets full hypervisor isolation.

**Why it's exciting**:
- Native Swift API (`import Containerization`)
- VM-per-container = stronger isolation than Docker
- Sub-second boot times (optimized kernel)
- OCI-compatible (works with existing images)
- Open source: https://github.com/apple/containerization

**Requirements**:
- macOS 26 (Tahoe) — currently in beta
- Apple Silicon only
- Xcode 26+

**Architecture**:
```
┌─────────────────────────────────────────────────────┐
│  Your App (Swift)                                   │
├─────────────────────────────────────────────────────┤
│  Containerization Framework                         │
│  ├── Image management (OCI registries)              │
│  ├── Container execution                            │
│  └── vminitd (Swift init system)                    │
├─────────────────────────────────────────────────────┤
│  Virtualization.framework                           │
├─────────────────────────────────────────────────────┤
│  Hypervisor.framework                               │
└─────────────────────────────────────────────────────┘
```

**Swift Usage** (from Apple's docs):
```swift
import Containerization

// Pull an image
let image = try await registry.pull("ubuntu:latest")

// Create and run container
let container = try await Container(
    image: image,
    command: ["/bin/bash"],
    mounts: [
        Mount(source: workspacePath, destination: "/workspace")
    ]
)

try await container.start()

// Execute commands
let result = try await container.exec(["git", "status"])
print(result.stdout)
```

**CLI tool** (`container`):
```bash
# Install from https://github.com/apple/container/releases
container system start

# Run a workspace
container run -it \
  -v /path/to/workspace:/workspace \
  --name my-workspace \
  ubuntu:latest /bin/bash

# Execute claude in the container
container exec my-workspace claude
```

**Pros**:
- Best isolation on Mac (VM-per-container)
- Native Swift integration
- Fast boot (~300ms)
- Apple-supported, open source

**Cons**:
- Requires macOS 26 (ships Fall 2025)
- Apple Silicon only
- Still maturing (v0.6.0)

---

## 2. Docker / Podman

**What it is**: The industry standard. Runs containers with shared Linux kernel via a VM on Mac.

**Swift Integration** (docker-client-swift):
```swift
import DockerClient

let client = DockerClient()

// Create container for workspace
let container = try await client.containers.create(
    name: "workspace-\(workspace.id)",
    image: "ubuntu:22.04",
    command: ["/bin/bash"],
    binds: ["\(workspace.path):/workspace:rw"],
    workingDir: "/workspace"
)

try await container.start()

// Execute commands
let exec = try await container.exec(
    command: ["git", "status"],
    attachStdout: true
)
```

**Or shell out to Docker CLI**:
```swift
func createDockerWorkspace(_ workspace: Workspace) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
    process.arguments = [
        "run", "-d",
        "--name", "ws-\(workspace.id.uuidString.prefix(8))",
        "-v", "\(workspace.path):/workspace",
        "-w", "/workspace",
        "ghcr.io/your-org/ai-coding-env:latest",
        "sleep", "infinity"
    ]
    try process.run()
    process.waitUntilExit()
}

func execInDocker(_ workspace: Workspace, command: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
    process.arguments = ["exec", "ws-\(workspace.id.uuidString.prefix(8))"] + command
    
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
```

**Pros**:
- Mature, well-documented
- Cross-platform
- Huge image ecosystem
- Works today (macOS 12+)

**Cons**:
- Requires Docker Desktop ($5/mo for business)
- Shared kernel = weaker isolation than VMs
- Resource overhead (Linux VM always running)
- Slower than Apple Container on Mac

---

## 3. Apple Virtualization.framework (Full VMs)

**What it is**: Run complete Linux VMs natively on Mac. More heavyweight than containers but maximum isolation.

**When to use**:
- Need complete OS isolation
- Running untrusted workloads
- Need specific kernel versions
- GUI applications in VM

**Swift Usage**:
```swift
import Virtualization

class LinuxVM {
    private var virtualMachine: VZVirtualMachine?
    
    func create(diskPath: URL, kernelPath: URL) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        // CPU & Memory
        config.cpuCount = 4
        config.memorySize = 4 * 1024 * 1024 * 1024  // 4GB
        
        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelPath)
        bootLoader.commandLine = "console=hvc0 root=/dev/vda"
        config.bootLoader = bootLoader
        
        // Storage
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskPath,
            readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        
        // Networking
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]
        
        // Directory sharing (workspace mount)
        let share = VZSingleDirectoryShare(directory: VZSharedDirectory(
            url: workspacePath,
            readOnly: false
        ))
        let sharingConfig = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
        sharingConfig.share = share
        config.directorySharingDevices = [sharingConfig]
        
        // Serial console for terminal
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        config.serialPorts = [serialPort]
        
        return config
    }
    
    func start() async throws {
        let config = try create(...)
        virtualMachine = VZVirtualMachine(configuration: config)
        try await virtualMachine?.start()
    }
}
```

**Pros**:
- Complete isolation
- Full Linux kernel control
- Works on macOS 12+
- No third-party dependencies

**Cons**:
- Slower boot (5-10s)
- Higher resource usage
- More complex setup
- Need to manage Linux images

---

## 4. Remote VMs (Fly.io, EC2, etc.)

**What it is**: Spin up cloud VMs on-demand, SSH into them for execution.

**Fly.io Example** (great developer experience):
```swift
struct FlyMachineBackend: WorkspaceBackend {
    private let apiToken: String
    private let appName: String
    
    func createMachine(for workspace: Workspace) async throws -> String {
        let url = URL(string: "https://api.machines.dev/v1/apps/\(appName)/machines")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "name": "ws-\(workspace.id.uuidString.prefix(8))",
            "config": [
                "image": "ghcr.io/your-org/ai-coding-env:latest",
                "size": "shared-cpu-2x",
                "mounts": [
                    ["volume": workspace.volumeId, "path": "/workspace"]
                ],
                "services": [
                    ["protocol": "tcp", "internal_port": 22, "ports": [["port": 22]]]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(FlyMachineResponse.self, from: data)
        return response.id
    }
    
    func sshConnect(machineId: String) async throws -> SSHConnection {
        // Use NMSSH or Citadel for SSH
        let connection = try await SSHConnection(
            host: "\(machineId).fly.dev",
            port: 22,
            username: "root",
            privateKey: sshPrivateKey
        )
        return connection
    }
}
```

**Fly.io CLI approach**:
```bash
# Create a dev environment machine
fly machine run ghcr.io/your-org/ai-coding-env:latest \
  --name ws-feature-123 \
  --region sjc \
  --size shared-cpu-2x \
  --volume workspace_vol:/workspace \
  -p 22:22/tcp

# SSH in
fly ssh console -a your-app -s ws-feature-123

# Or use WireGuard for direct access
fly wireguard create
ssh root@ws-feature-123.internal
```

**Pros**:
- Maximum isolation
- Access to GPUs
- Scale compute on-demand
- Global regions (low latency)
- Pay only when running (auto-stop)

**Cons**:
- Network latency
- Requires internet
- API keys / billing
- Cold start time (~30-60s)

---

## 5. Abstraction Layer Design

Create a protocol that all backends implement:

```swift
// MARK: - Protocol

protocol WorkspaceBackend: Actor {
    /// Unique identifier for this backend type
    static var identifier: String { get }
    
    /// Human-readable name
    static var displayName: String { get }
    
    /// Check if this backend is available on the current system
    static func isAvailable() async -> Bool
    
    /// Initialize a workspace environment
    func initialize(workspace: Workspace) async throws
    
    /// Start the workspace environment
    func start(workspace: Workspace) async throws
    
    /// Stop the workspace environment
    func stop(workspace: Workspace) async throws
    
    /// Destroy the workspace environment and clean up
    func destroy(workspace: Workspace) async throws
    
    /// Execute a command in the workspace
    func execute(
        command: [String],
        in workspace: Workspace,
        environment: [String: String]
    ) async throws -> ProcessResult
    
    /// Get an interactive terminal connection
    func getTerminal(for workspace: Workspace) async throws -> TerminalConnection
    
    /// Get the filesystem path accessible from the host (if any)
    func hostPath(for workspace: Workspace) -> URL?
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol TerminalConnection {
    func send(_ data: Data)
    var onReceive: ((Data) -> Void)? { get set }
    var onResize: ((Int, Int) -> Void)? { get set }
    func resize(cols: Int, rows: Int)
    func close()
}

// MARK: - Backend Registry

actor BackendRegistry {
    static let shared = BackendRegistry()
    
    private var backends: [String: any WorkspaceBackend.Type] = [:]
    
    func register<T: WorkspaceBackend>(_ backend: T.Type) {
        backends[T.identifier] = backend
    }
    
    func availableBackends() async -> [any WorkspaceBackend.Type] {
        var available: [any WorkspaceBackend.Type] = []
        for (_, backend) in backends {
            if await backend.isAvailable() {
                available.append(backend)
            }
        }
        return available
    }
    
    func backend(for identifier: String) -> (any WorkspaceBackend.Type)? {
        backends[identifier]
    }
}

// MARK: - Implementations

// 1. Local (No Isolation)
actor LocalBackend: WorkspaceBackend {
    static let identifier = "local"
    static let displayName = "Local (No Isolation)"
    
    static func isAvailable() async -> Bool { true }
    
    func initialize(workspace: Workspace) async throws {
        // Nothing to do - workspace directory already exists
    }
    
    func start(workspace: Workspace) async throws {
        // Nothing to do
    }
    
    func stop(workspace: Workspace) async throws {
        // Nothing to do
    }
    
    func destroy(workspace: Workspace) async throws {
        try FileManager.default.removeItem(at: workspace.workspaceURL)
    }
    
    func execute(
        command: [String],
        in workspace: Workspace,
        environment: [String: String]
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = workspace.workspaceURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        process.waitUntilExit()
        
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
    
    func getTerminal(for workspace: Workspace) async throws -> TerminalConnection {
        return LocalTerminalConnection(workingDirectory: workspace.workspaceURL)
    }
    
    func hostPath(for workspace: Workspace) -> URL? {
        workspace.workspaceURL
    }
}

// 2. Apple Container (when available)
actor AppleContainerBackend: WorkspaceBackend {
    static let identifier = "apple-container"
    static let displayName = "Apple Container (Isolated)"
    
    private var containerIds: [UUID: String] = [:]
    
    static func isAvailable() async -> Bool {
        // Check for macOS 26+ and container CLI
        guard #available(macOS 26, *) else { return false }
        return FileManager.default.fileExists(atPath: "/usr/local/bin/container")
    }
    
    func initialize(workspace: Workspace) async throws {
        // Pull base image if needed
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = ["image", "pull", "ubuntu:latest"]
        try process.run()
        process.waitUntilExit()
    }
    
    func start(workspace: Workspace) async throws {
        let containerName = "ws-\(workspace.id.uuidString.prefix(8))"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = [
            "run", "-d",
            "--name", containerName,
            "-v", "\(workspace.workspaceURL.path):/workspace",
            "ubuntu:latest",
            "sleep", "infinity"
        ]
        try process.run()
        process.waitUntilExit()
        
        containerIds[workspace.id] = containerName
    }
    
    func stop(workspace: Workspace) async throws {
        guard let name = containerIds[workspace.id] else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = ["stop", name]
        try process.run()
        process.waitUntilExit()
    }
    
    func destroy(workspace: Workspace) async throws {
        guard let name = containerIds[workspace.id] else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = ["rm", "-f", name]
        try process.run()
        process.waitUntilExit()
        
        containerIds.removeValue(forKey: workspace.id)
    }
    
    func execute(
        command: [String],
        in workspace: Workspace,
        environment: [String: String]
    ) async throws -> ProcessResult {
        guard let name = containerIds[workspace.id] else {
            throw BackendError.workspaceNotRunning
        }
        
        var args = ["exec"]
        for (key, value) in environment {
            args += ["-e", "\(key)=\(value)"]
        }
        args += [name] + command
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container")
        process.arguments = args
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        process.waitUntilExit()
        
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
    
    func getTerminal(for workspace: Workspace) async throws -> TerminalConnection {
        guard let name = containerIds[workspace.id] else {
            throw BackendError.workspaceNotRunning
        }
        return ContainerTerminalConnection(containerName: name, tool: "/usr/local/bin/container")
    }
    
    func hostPath(for workspace: Workspace) -> URL? {
        workspace.workspaceURL  // Mounted into container
    }
}

// 3. Docker Backend
actor DockerBackend: WorkspaceBackend {
    static let identifier = "docker"
    static let displayName = "Docker Container"
    
    private var containerIds: [UUID: String] = [:]
    
    static func isAvailable() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["docker"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    
    func initialize(workspace: Workspace) async throws {
        // Similar to AppleContainerBackend but using docker CLI
    }
    
    func start(workspace: Workspace) async throws {
        let containerName = "ws-\(workspace.id.uuidString.prefix(8))"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = [
            "run", "-d",
            "--name", containerName,
            "-v", "\(workspace.workspaceURL.path):/workspace",
            "-w", "/workspace",
            "ubuntu:latest",
            "sleep", "infinity"
        ]
        try process.run()
        process.waitUntilExit()
        
        containerIds[workspace.id] = containerName
    }
    
    // ... similar implementation to AppleContainerBackend
    
    func stop(workspace: Workspace) async throws { /* ... */ }
    func destroy(workspace: Workspace) async throws { /* ... */ }
    func execute(command: [String], in workspace: Workspace, environment: [String: String]) async throws -> ProcessResult {
        fatalError("Implement similar to AppleContainerBackend")
    }
    func getTerminal(for workspace: Workspace) async throws -> TerminalConnection {
        guard let name = containerIds[workspace.id] else {
            throw BackendError.workspaceNotRunning
        }
        return ContainerTerminalConnection(containerName: name, tool: "/usr/local/bin/docker")
    }
    func hostPath(for workspace: Workspace) -> URL? { workspace.workspaceURL }
}

// 4. Fly.io Backend
actor FlyBackend: WorkspaceBackend {
    static let identifier = "fly"
    static let displayName = "Fly.io Remote VM"
    
    private let apiToken: String
    private let appName: String
    private var machineIds: [UUID: String] = [:]
    
    init(apiToken: String, appName: String) {
        self.apiToken = apiToken
        self.appName = appName
    }
    
    static func isAvailable() async -> Bool {
        // Check if flyctl is installed and authenticated
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["flyctl"]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    
    func start(workspace: Workspace) async throws {
        // Use Fly Machines API to create a new machine
        // See earlier code example
    }
    
    // Remote execution via SSH
    func execute(
        command: [String],
        in workspace: Workspace,
        environment: [String: String]
    ) async throws -> ProcessResult {
        guard let machineId = machineIds[workspace.id] else {
            throw BackendError.workspaceNotRunning
        }
        
        // Use fly ssh console or direct SSH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/flyctl")
        process.arguments = [
            "ssh", "console",
            "-a", appName,
            "-s", machineId,
            "-C", command.joined(separator: " ")
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: ""
        )
    }
    
    func initialize(workspace: Workspace) async throws { /* ... */ }
    func stop(workspace: Workspace) async throws { /* ... */ }
    func destroy(workspace: Workspace) async throws { /* ... */ }
    func getTerminal(for workspace: Workspace) async throws -> TerminalConnection {
        fatalError("Implement SSH terminal connection")
    }
    func hostPath(for workspace: Workspace) -> URL? { nil }  // No local path for remote
}

// MARK: - Errors

enum BackendError: LocalizedError {
    case workspaceNotRunning
    case backendNotAvailable
    case initializationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .workspaceNotRunning: return "Workspace is not running"
        case .backendNotAvailable: return "Backend is not available on this system"
        case .initializationFailed(let reason): return "Failed to initialize: \(reason)"
        }
    }
}
```

---

## 6. Integration with Workspace Manager App

Update the `Workspace` model to track backend:

```swift
@Model
final class Workspace {
    // ... existing properties ...
    
    /// Which isolation backend to use
    var backendIdentifier: String = "local"
    
    /// Backend-specific state (container ID, machine ID, etc.)
    var backendState: Data?  // JSON-encoded
}

// In your app
class WorkspaceManager: ObservableObject {
    private var backends: [String: any WorkspaceBackend] = [:]
    
    init() {
        // Register available backends
        backends["local"] = LocalBackend()
        backends["docker"] = DockerBackend()
        
        if #available(macOS 26, *) {
            backends["apple-container"] = AppleContainerBackend()
        }
        
        // Remote backends need configuration
        if let flyToken = UserDefaults.standard.string(forKey: "flyApiToken") {
            backends["fly"] = FlyBackend(apiToken: flyToken, appName: "workspaces")
        }
    }
    
    func startWorkspace(_ workspace: Workspace) async throws {
        guard let backend = backends[workspace.backendIdentifier] else {
            throw BackendError.backendNotAvailable
        }
        
        try await backend.initialize(workspace: workspace)
        try await backend.start(workspace: workspace)
    }
    
    func getTerminal(for workspace: Workspace) async throws -> TerminalConnection {
        guard let backend = backends[workspace.backendIdentifier] else {
            throw BackendError.backendNotAvailable
        }
        return try await backend.getTerminal(for: workspace)
    }
}
```

---

## 7. Recommendations

### For MVP (Now)
1. **Start with `LocalBackend`** — zero complexity, works today
2. **Add `DockerBackend`** as optional — familiar to users, works on macOS 12+
3. **Design the protocol** so you can add more backends later

### For Production (Fall 2025)
1. **Add `AppleContainerBackend`** when macOS 26 ships
2. **Make it the default** for new workspaces on compatible systems
3. **Keep Docker as fallback** for Intel Macs

### For Advanced Use Cases
1. **Add `FlyBackend`** for users who need:
   - GPU access
   - More compute than local machine
   - Running truly untrusted code
   - Team/shared environments

### Suggested UI

```
┌─ New Workspace ────────────────────────────────┐
│                                                │
│  Name: feature-auth                            │
│                                                │
│  Isolation:                                    │
│  ┌─────────────────────────────────────────┐   │
│  │ ○ None (Local)                          │   │
│  │   Fastest. Files in ~/Workspaces        │   │
│  │                                         │   │
│  │ ● Apple Container (Recommended)         │   │
│  │   Isolated Linux VM. ~300ms startup     │   │
│  │                                         │   │
│  │ ○ Docker                                │   │
│  │   Standard containers. Requires Docker  │   │
│  │                                         │   │
│  │ ○ Remote VM (Fly.io)                    │   │
│  │   Cloud VM. Configure in Settings...    │   │
│  └─────────────────────────────────────────┘   │
│                                                │
│                      [Cancel]  [Create]        │
└────────────────────────────────────────────────┘
```

---

## 8. Security Considerations

| Threat | Local | Container | VM | Remote |
|--------|-------|-----------|----|----|
| File system escape | ❌ None | ✅ Isolated | ✅ Isolated | ✅ Isolated |
| Network access | ❌ Full | ⚠️ Configurable | ⚠️ Configurable | ✅ Isolated |
| Resource exhaustion | ❌ None | ✅ cgroups | ✅ Limited | ✅ Limited |
| Kernel exploits | ❌ Vulnerable | ⚠️ Shared kernel* | ✅ Isolated | ✅ Isolated |
| Host process visibility | ❌ Full | ✅ Hidden | ✅ Hidden | ✅ Hidden |

*Apple Container uses VM-per-container, so kernel exploits are also mitigated.

---

## Resources

**Apple Containerization**:
- Framework: https://github.com/apple/containerization
- CLI: https://github.com/apple/container
- WWDC 2025: https://developer.apple.com/videos/play/wwdc2025/346/
- Docs: https://apple.github.io/container/documentation/

**Docker**:
- Swift client: https://github.com/alexsteinerde/docker-client-swift
- Docker Desktop: https://www.docker.com/products/docker-desktop/

**Apple Virtualization**:
- Framework: https://developer.apple.com/documentation/virtualization
- WWDC 2022: https://developer.apple.com/videos/play/wwdc2022/10002/
- SimpleVM: https://github.com/KhaosT/SimpleVM

**Remote VMs**:
- Fly.io Machines API: https://fly.io/docs/machines/
- Fly.io SSH: https://fly.io/docs/flyctl/ssh/
- VS Code Remote on Fly: https://fly.io/docs/app-guides/vscode-remote/
