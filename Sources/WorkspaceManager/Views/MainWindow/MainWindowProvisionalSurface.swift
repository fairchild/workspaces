//
//  MainWindowProvisionalSurface.swift
//  WorkspaceManager
//
//  Shows a launch surface without letting it become the saved one (#845).
//
//  Selection writes the last surface on its way through, which is right for a
//  choice and wrong for a stand-in: a saved surface still awaiting the models
//  that would judge it has to be there to restore when they land. This is a free
//  function rather than a method on the view so the restore is reachable by a
//  test — stubbing the view's action closure would leave a suite green while the
//  restore itself was deleted.
//

import Foundation

enum MainWindowProvisionalSurface {
    /// Runs `apply`, then puts back whatever saved value it displaced.
    ///
    /// The value is restored rather than suppressed at the selection layer so
    /// this path shares the production selection code exactly and differs only
    /// in what it leaves behind.
    static func applyPreservingSavedSurface(
        readRawValue: () -> String,
        writeRawValue: (String) -> Void,
        apply: () -> Void
    ) {
        let awaitingRawValue = readRawValue()
        apply()
        if readRawValue() != awaitingRawValue {
            writeRawValue(awaitingRawValue)
        }
    }
}
