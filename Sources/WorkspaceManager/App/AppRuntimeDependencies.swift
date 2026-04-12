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
    let telemetryService: DesktopTelemetryService

    static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppRuntimeDependencies {
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
                telemetryService: .disabled
            )
        }

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
            telemetryService: DesktopTelemetryService.live(environment: environment)
        )
    }
}
