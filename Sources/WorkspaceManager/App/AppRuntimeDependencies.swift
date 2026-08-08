//
//  AppRuntimeDependencies.swift
//  WorkspaceManager
//
//  Runtime service wiring, including deterministic UI-fixture overrides.
//

import Foundation
import WorkspaceManagerCore

struct AppRuntimeDependencies {
    let lumeRuntimeService: any LumeRuntimeServiceProtocol
    let workspaceProviderRegistry: WorkspaceProviderRegistry
    /// Supervisor for the embedded local-mode web-next server. Constructed here
    /// but not started — activation of the embedded surface starts it lazily.
    let webNextServerService: any WebNextServerServiceProtocol

    static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppRuntimeDependencies {
        let webNextServerService = makeWebNextServerService()

        #if DEBUG
            if UIFixtureLumeEnvironment.isEnabled(environment: environment) {
                let runtimeService = UIFixtureLumeRuntimeService()
                return AppRuntimeDependencies(
                    lumeRuntimeService: runtimeService,
                    workspaceProviderRegistry: WorkspaceProviderRegistry(
                        providers: [
                            LocalWorkspaceProvider(),
                            UIFixtureDaytonaWorkspaceProvider(),
                            UIFixtureLumeWorkspaceProvider(runtimeService: runtimeService),
                        ]
                    ),
                    webNextServerService: webNextServerService
                )
            }
        #endif

        let runtimeService: any LumeRuntimeServiceProtocol = DeferredLumeRuntimeService {
            LumeRuntimeService.shared
        }
        return AppRuntimeDependencies(
            lumeRuntimeService: runtimeService,
            workspaceProviderRegistry: WorkspaceProviderRegistry(
                providers: [
                    LocalWorkspaceProvider(),
                    DeferredWorkspaceProvider(
                        descriptor: DaytonaWorkspaceProvider.providerDescriptor,
                        sessionKeyProvider: { workspace in
                            .backendSession(
                                providerID: DaytonaWorkspaceProvider.identifier,
                                instanceID: workspace.terminalSessionIdentifier
                            )
                        }
                    ) {
                        DaytonaWorkspaceProvider()
                    },
                    DeferredWorkspaceProvider(
                        descriptor: LumeWorkspaceProvider.providerDescriptor,
                        sessionKeyProvider: { workspace in
                            .backendSession(
                                providerID: LumeWorkspaceProvider.identifier,
                                instanceID: workspace.terminalSessionIdentifier
                            )
                        }
                    ) {
                        LumeWorkspaceProvider(runtimeService: runtimeService)
                    },
                ]
            ),
            webNextServerService: webNextServerService
        )
    }

    /// Build (not start) the embedded web-next supervisor from resolved settings
    /// and register it for clean shutdown on app termination.
    private static func makeWebNextServerService() -> any WebNextServerServiceProtocol {
        let service = WebNextServerService(
            configuration: WebNextServerSettings.resolvedConfiguration()
        )
        WebNextServerLifecycle.shared.register(service)
        return service
    }
}
