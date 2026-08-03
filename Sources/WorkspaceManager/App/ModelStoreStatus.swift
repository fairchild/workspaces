import Foundation
import SwiftData
import SwiftUI
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "ModelStoreStatus")

enum ModelStoreMode: Codable, Equatable {
    case persistentAppSupport(path: String)
    case persistentWorkspaceLocal(path: String)
    case inMemoryDegraded

    var path: String? {
        switch self {
        case .persistentAppSupport(let path), .persistentWorkspaceLocal(let path):
            return path
        case .inMemoryDegraded:
            return nil
        }
    }

    var label: String {
        switch self {
        case .persistentAppSupport:
            return "Persistent (Primary)"
        case .persistentWorkspaceLocal:
            return "Persistent (Workspace Local Fallback)"
        case .inMemoryDegraded:
            return "In-Memory Degraded Mode"
        }
    }
}

struct ModelStoreBootstrapResult {
    let container: ModelContainer
    let mode: ModelStoreMode
    let bootstrapErrors: [String]
}

struct ModelStoreStatusSnapshot: Codable, Equatable {
    let mode: ModelStoreMode
    let bootstrapErrors: [String]
}

@MainActor
final class ModelStoreStatusController: ObservableObject {
    static let shared = ModelStoreStatusController()

    @Published private(set) var mode: ModelStoreMode = .inMemoryDegraded
    @Published private(set) var bootstrapErrors: [String] = []

    var snapshot: ModelStoreStatusSnapshot {
        ModelStoreStatusSnapshot(
            mode: mode,
            bootstrapErrors: bootstrapErrors
        )
    }

    var shouldShowDegradedWarning: Bool {
        mode == .inMemoryDegraded && !bootstrapErrors.isEmpty
    }

    func apply(_ result: ModelStoreBootstrapResult) {
        mode = result.mode
        bootstrapErrors = result.bootstrapErrors
    }
}

enum ModelStoreBootstrapper {
    static func bootstrap(
        schema: Schema,
        launchEnvironment: [String: String],
        fileManager: FileManager = .default,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        appSupportDirectoryProvider: ((FileManager) throws -> URL)? = nil
    ) -> ModelStoreBootstrapResult {
        let shouldUseInMemoryStore = launchEnvironment["WORKSPACES_UI_FIXTURE"] == "1"
        if shouldUseInMemoryStore {
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            let container = makeContainer(
                schema: schema,
                configuration: configuration,
                fatalContext: "fixture in-memory"
            )
            return ModelStoreBootstrapResult(
                container: container,
                mode: .inMemoryDegraded,
                bootstrapErrors: []
            )
        }

        var bootstrapErrors: [String] = []

        if let requestedDataDirectory = launchEnvironment["WORKSPACES_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !requestedDataDirectory.isEmpty
        {
            let expandedPath = (requestedDataDirectory as NSString).expandingTildeInPath
            let requestedURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
            do {
                let configuration = try persistentModelConfiguration(
                    schema: schema,
                    storeDirectory: requestedURL,
                    fileManager: fileManager
                )
                let container = makeContainer(
                    schema: schema,
                    configuration: configuration,
                    fatalContext: "requested persistent store"
                )
                return ModelStoreBootstrapResult(
                    container: container,
                    mode: .persistentAppSupport(path: requestedURL.path),
                    bootstrapErrors: []
                )
            } catch {
                let message =
                    "Failed to use WORKSPACES_DATA_DIR '\(requestedURL.path)': \(String(describing: error))"
                log.error("[ModelStore] \(message, privacy: .public)")
                bootstrapErrors.append(message)
            }
        }

        do {
            let resolvedProvider = appSupportDirectoryProvider ?? defaultModelStoreDirectory
            let appSupportDirectory = try resolvedProvider(fileManager)
            let configuration = try persistentModelConfiguration(
                schema: schema,
                storeDirectory: appSupportDirectory,
                fileManager: fileManager
            )
            let container = makeContainer(
                schema: schema,
                configuration: configuration,
                fatalContext: "primary persistent store"
            )
            return ModelStoreBootstrapResult(
                container: container,
                mode: .persistentAppSupport(path: appSupportDirectory.path),
                bootstrapErrors: bootstrapErrors
            )
        } catch {
            let message = "Falling back from app-support store: \(String(describing: error))"
            log.error("[ModelStore] \(message, privacy: .public)")
            bootstrapErrors.append(message)
        }

        let fallbackDirectory = URL(
            fileURLWithPath: currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".workspacemanager-data", isDirectory: true)

        do {
            let configuration = try persistentModelConfiguration(
                schema: schema,
                storeDirectory: fallbackDirectory,
                fileManager: fileManager
            )
            let container = makeContainer(
                schema: schema,
                configuration: configuration,
                fatalContext: "workspace-local persistent store"
            )
            return ModelStoreBootstrapResult(
                container: container,
                mode: .persistentWorkspaceLocal(path: fallbackDirectory.path),
                bootstrapErrors: bootstrapErrors
            )
        } catch {
            let message =
                "Falling back from workspace-local store (\(fallbackDirectory.path)): \(String(describing: error))"
            log.error("[ModelStore] \(message, privacy: .public)")
            bootstrapErrors.append(message)
        }

        log.info("[ModelStore] Falling back to in-memory store")
        let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = makeContainer(
            schema: schema,
            configuration: inMemoryConfig,
            fatalContext: "degraded in-memory store"
        )
        return ModelStoreBootstrapResult(
            container: container,
            mode: .inMemoryDegraded,
            bootstrapErrors: bootstrapErrors
        )
    }

    private static func makeContainer(
        schema: Schema,
        configuration: ModelConfiguration,
        fatalContext: String
    ) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer for \(fatalContext): \(error)")
        }
    }
}

func defaultModelStoreDirectory(fileManager: FileManager = .default) throws -> URL {
    let appSupportDirectory = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let modelDirectory = appSupportDirectory.appendingPathComponent("WorkspaceManager", isDirectory: true)
    try ensureWritableDirectory(at: modelDirectory, fileManager: fileManager)
    return modelDirectory
}

func persistentModelConfiguration(
    schema: Schema,
    storeDirectory: URL,
    fileManager: FileManager = .default
) throws -> ModelConfiguration {
    try ensureWritableDirectory(at: storeDirectory, fileManager: fileManager)
    let storeURL = storeDirectory.appendingPathComponent("default.store", isDirectory: false)
    return ModelConfiguration(
        schema: schema,
        url: storeURL
    )
}

func ensureWritableDirectory(
    at directory: URL,
    fileManager: FileManager = .default
) throws {
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )

    let probeURL = directory.appendingPathComponent(
        ".write-probe-\(UUID().uuidString)",
        isDirectory: false
    )
    try Data("ok".utf8).write(to: probeURL, options: .atomic)
    try fileManager.removeItem(at: probeURL)
}

struct ModelStoreDegradedBanner: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Persistence is degraded. Changes will not survive relaunch.")
                    .font(.callout.weight(.semibold))
                Text("Open Settings > Diagnostics for active store mode and bootstrap failures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
