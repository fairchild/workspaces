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

    enum TabActionKind: String {
        case newTab = "new_tab"
        case closeTab = "close_tab"
        case gotoTab = "goto_tab"
        case moveTab = "move_tab"
        case setTabTitle = "set_tab_title"
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

    enum TabCloseMode: Int {
        case this = 0
        case other = 1
        case right = 2
    }

    enum TabGotoTarget: Equatable {
        case previous
        case next
        case last
        case index(Int)
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

    struct TabActionRequest {
        let kind: TabActionKind
        let closeModeRawValue: Int?
        let gotoRawValue: Int?
        let moveAmount: Int?
        let title: String?

        var closeMode: TabCloseMode {
            guard let closeModeRawValue,
                let mode = TabCloseMode(rawValue: closeModeRawValue)
            else {
                return .this
            }
            return mode
        }

        var gotoTarget: TabGotoTarget? {
            guard let gotoRawValue else { return nil }
            switch gotoRawValue {
            case -1:
                return .previous
            case -2:
                return .next
            case -3:
                return .last
            default:
                guard gotoRawValue > 0 else { return nil }
                return .index(gotoRawValue)
            }
        }
    }

    static let splitActionNotification = Notification.Name("WorkspaceManager.Ghostty.SplitActionRequested")
    static let splitActionKindUserInfoKey = "kind"
    static let splitActionDirectionUserInfoKey = "directionRawValue"
    static let splitActionAmountUserInfoKey = "amount"

    static let tabActionNotification = Notification.Name("WorkspaceManager.Ghostty.TabActionRequested")
    static let tabActionKindUserInfoKey = "kind"
    static let tabActionCloseModeUserInfoKey = "closeModeRawValue"
    static let tabActionGotoUserInfoKey = "gotoRawValue"
    static let tabActionMoveAmountUserInfoKey = "moveAmount"
    static let tabActionTitleUserInfoKey = "title"

    static func handle(
        target: ghostty_target_s,
        action: ghostty_action_s,
        resolveSurfaceAddress: (ghostty_target_s) -> UInt?,
        resolveSurfaceView: @MainActor @Sendable @escaping (UInt?) -> GhosttySurfaceView?,
        runOnMainAsync: (@escaping @MainActor @Sendable () -> Void) -> Void
    ) -> Bool {
        guard let sourceSurfaceAddress = resolveSurfaceAddress(target) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB:
            postTabAction(
                kind: .newTab,
                closeModeRawValue: nil,
                gotoRawValue: nil,
                moveAmount: nil,
                title: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=new_tab")
            return true

        case GHOSTTY_ACTION_CLOSE_TAB:
            let closeModeRawValue = Int(action.action.close_tab_mode.rawValue)
            postTabAction(
                kind: .closeTab,
                closeModeRawValue: closeModeRawValue,
                gotoRawValue: nil,
                moveAmount: nil,
                title: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=close_tab mode=%d", closeModeRawValue)
            return true

        case GHOSTTY_ACTION_GOTO_TAB:
            let gotoRawValue = Int(action.action.goto_tab.rawValue)
            postTabAction(
                kind: .gotoTab,
                closeModeRawValue: nil,
                gotoRawValue: gotoRawValue,
                moveAmount: nil,
                title: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=goto_tab target=%d", gotoRawValue)
            return true

        case GHOSTTY_ACTION_MOVE_TAB:
            let moveAmount = Int(action.action.move_tab.amount)
            postTabAction(
                kind: .moveTab,
                closeModeRawValue: nil,
                gotoRawValue: nil,
                moveAmount: moveAmount,
                title: nil,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
            NSLog("[GhosttyAppManager] action=move_tab amount=%d", moveAmount)
            return true

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

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.action.set_tab_title.title.flatMap { String(cString: $0) } ?? ""
            postTabAction(
                kind: .setTabTitle,
                closeModeRawValue: nil,
                gotoRawValue: nil,
                moveAmount: nil,
                title: title,
                sourceSurfaceAddress: sourceSurfaceAddress,
                resolveSurfaceView: resolveSurfaceView,
                runOnMainAsync: runOnMainAsync
            )
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

    static func tabActionRequest(from notification: Notification) -> TabActionRequest? {
        guard let userInfo = notification.userInfo,
            let kindRawValue = userInfo[tabActionKindUserInfoKey] as? String,
            let kind = TabActionKind(rawValue: kindRawValue)
        else {
            return nil
        }

        return TabActionRequest(
            kind: kind,
            closeModeRawValue: userInfo[tabActionCloseModeUserInfoKey] as? Int,
            gotoRawValue: userInfo[tabActionGotoUserInfoKey] as? Int,
            moveAmount: userInfo[tabActionMoveAmountUserInfoKey] as? Int,
            title: userInfo[tabActionTitleUserInfoKey] as? String
        )
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

    private static func postTabAction(
        kind: TabActionKind,
        closeModeRawValue: Int?,
        gotoRawValue: Int?,
        moveAmount: Int?,
        title: String?,
        sourceSurfaceAddress: UInt,
        resolveSurfaceView: @MainActor @Sendable @escaping (UInt?) -> GhosttySurfaceView?,
        runOnMainAsync: (@escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        runOnMainAsync {
            guard let sourceSurfaceView = resolveSurfaceView(sourceSurfaceAddress) else { return }

            var userInfo: [String: Any] = [
                tabActionKindUserInfoKey: kind.rawValue
            ]
            if let closeModeRawValue {
                userInfo[tabActionCloseModeUserInfoKey] = closeModeRawValue
            }
            if let gotoRawValue {
                userInfo[tabActionGotoUserInfoKey] = gotoRawValue
            }
            if let moveAmount {
                userInfo[tabActionMoveAmountUserInfoKey] = moveAmount
            }
            if let title {
                userInfo[tabActionTitleUserInfoKey] = title
            }

            NotificationCenter.default.post(
                name: tabActionNotification,
                object: sourceSurfaceView,
                userInfo: userInfo
            )
        }
    }
}
