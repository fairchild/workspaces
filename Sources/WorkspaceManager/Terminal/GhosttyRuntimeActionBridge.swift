//
//  GhosttyRuntimeActionBridge.swift
//  WorkspaceManager
//

import Foundation
import GhosttyKit

enum GhosttyRuntimeActionBridge {
    enum SplitActionKind: String {
        case newSplit = "new_split"
        case gotoSplit = "goto_split"
        case resizeSplit = "resize_split"
        case equalizeSplits = "equalize_splits"
    }

    enum SplitDirection: Int {
        case right = 0
        case down = 1
        case left = 2
        case up = 3
    }

    enum SplitFocusDirection: Int {
        case previous = 0
        case next = 1
        case up = 2
        case left = 3
        case down = 4
        case right = 5
    }

    enum SplitResizeDirection: Int {
        case up = 0
        case down = 1
        case left = 2
        case right = 3
    }

    struct SplitActionRequest {
        let kind: SplitActionKind
        let directionRawValue: Int?
        let amount: Int?

        var splitDirection: SplitDirection? {
            guard let directionRawValue else { return nil }
            return SplitDirection(rawValue: directionRawValue)
        }

        var focusDirection: SplitFocusDirection? {
            guard let directionRawValue else { return nil }
            return SplitFocusDirection(rawValue: directionRawValue)
        }

        var resizeDirection: SplitResizeDirection? {
            guard let directionRawValue else { return nil }
            return SplitResizeDirection(rawValue: directionRawValue)
        }
    }

    static let splitActionNotification = Notification.Name("WorkspaceManager.Ghostty.SplitActionRequested")
    static let splitActionKindUserInfoKey = "kind"
    static let splitActionDirectionUserInfoKey = "directionRawValue"
    static let splitActionAmountUserInfoKey = "amount"

    static func handle(
        target: ghostty_target_s,
        action: ghostty_action_s,
        resolveSurfaceAddress: (ghostty_target_s) -> UInt?,
        resolveSurfaceView: @MainActor @Sendable @escaping (UInt?) -> GhosttySurfaceView?,
        runOnMainAsync: (@escaping @MainActor @Sendable () -> Void) -> Void
    ) -> Bool {
        guard let sourceSurfaceAddress = resolveSurfaceAddress(target) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            let directionRawValue = Int(action.action.new_split.rawValue)
            postSplitAction(
                kind: .newSplit,
                directionRawValue: directionRawValue,
                amount: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=new_split direction=%d", directionRawValue)
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let directionRawValue = Int(action.action.goto_split.rawValue)
            postSplitAction(
                kind: .gotoSplit,
                directionRawValue: directionRawValue,
                amount: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=goto_split direction=%d", directionRawValue)
            return true

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let directionRawValue = Int(action.action.resize_split.direction.rawValue)
            let amount = Int(action.action.resize_split.amount)
            postSplitAction(
                kind: .resizeSplit,
                directionRawValue: directionRawValue,
                amount: amount,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog(
                "[GhosttyAppManager] action=resize_split direction=%d amount=%d",
                directionRawValue,
                amount
            )
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            postSplitAction(
                kind: .equalizeSplits,
                directionRawValue: nil,
                amount: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=equalize_splits")
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title.flatMap { String(cString: $0) } ?? ""
            runOnMainAsync {
                guard let surfaceView = resolveSurfaceView(sourceSurfaceAddress) else { return }
                surfaceView.updateTerminalTitle(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) }
            runOnMainAsync {
                guard let surfaceView = resolveSurfaceView(sourceSurfaceAddress) else { return }
                surfaceView.updateWorkingDirectory(pwd)
            }
            return true

        default:
            return false
        }
    }

    static func splitActionRequest(from notification: Notification) -> SplitActionRequest? {
        guard let userInfo = notification.userInfo,
            let kindRawValue = userInfo[splitActionKindUserInfoKey] as? String,
            let kind = SplitActionKind(rawValue: kindRawValue)
        else {
            return nil
        }

        let directionRawValue = userInfo[splitActionDirectionUserInfoKey] as? Int
        let amount = userInfo[splitActionAmountUserInfoKey] as? Int
        return SplitActionRequest(
            kind: kind,
            directionRawValue: directionRawValue,
            amount: amount
        )
    }

    private static func postSplitAction(
        kind: SplitActionKind,
        directionRawValue: Int?,
        amount: Int?,
        sourceSurfaceAddress: UInt,
        resolveSurfaceView: @MainActor @Sendable @escaping (UInt?) -> GhosttySurfaceView?,
        runOnMainAsync: (@escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        runOnMainAsync {
            guard let sourceSurfaceView = resolveSurfaceView(sourceSurfaceAddress) else { return }

            var userInfo: [String: Any] = [
                splitActionKindUserInfoKey: kind.rawValue
            ]
            if let directionRawValue {
                userInfo[splitActionDirectionUserInfoKey] = directionRawValue
            }
            if let amount {
                userInfo[splitActionAmountUserInfoKey] = amount
            }

            NotificationCenter.default.post(
                name: splitActionNotification,
                object: sourceSurfaceView,
                userInfo: userInfo
            )
        }
    }
}
