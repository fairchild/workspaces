//
//  GhosttySurfacePromptReadinessTests.swift
//  WorkspaceManagerAppTests
//
//  Covers the prompt-readiness latch a surface exposes to the Automation API's `prompt_ready`
//  wait condition: readiness is a fact about the past, so nothing that happens after the shell
//  first reports in can take it back.
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttySurface prompt readiness")
@MainActor
struct GhosttySurfacePromptReadinessTests {
    @Test("A fresh surface has not observed a readiness signal")
    func freshSurfaceIsNotReady() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)

        #expect(view.hasObservedPromptReadySignal == false)
    }

    @Test("A cleared title and a dropped pwd cannot un-ready a surface")
    func readinessLatchesPastTitleAndDirectoryResets() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)

        view.updateTerminalTitle("zsh — ~/code")
        #expect(view.hasObservedPromptReadySignal)

        // A TUI exiting resets the window title, and a shell without a pwd hook reports none.
        // Both are ordinary mid-session states, and both leave the surface ready.
        view.updateTerminalTitle("")
        view.updateWorkingDirectory(nil)
        #expect(view.hasObservedPromptReadySignal)
    }

    @Test("A pwd report alone latches readiness")
    func workingDirectorySignalLatchesReadiness() {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)

        view.updateWorkingDirectory("/tmp/repo")
        #expect(view.hasObservedPromptReadySignal)

        view.updateWorkingDirectory(nil)
        #expect(view.hasObservedPromptReadySignal)
    }
}
