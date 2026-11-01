//
//  SerialPassRunner.swift
//  WorkspaceManager
//
//  Runs an async pass one at a time. Main-actor isolation stops two passes running at
//  once between suspensions, not across them, so a pass that reads shared state, awaits
//  and writes it back needs this to see its own read still true at the write.
//

import Foundation

@MainActor
final class SerialPassRunner {
    private var isRunning = false
    private var isRequested = false

    /// Runs `pass`, or if one is under way, asks for one more after it: a request made
    /// during a pass may concern something that pass already read past. Returns once the
    /// passes this call started have finished, and at once if it only asked.
    func run(_ pass: @MainActor () async -> Void) async {
        isRequested = true
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while isRequested {
            isRequested = false
            await pass()
        }
    }
}
