//
//  RepoLandingBridge.swift
//  WorkspaceManager
//
//  JS ↔ Swift bridge for the web-based repo landing page.
//

import Foundation
import WebKit

@MainActor
final class RepoLandingBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "repoLanding"

    private(set) weak var webView: WKWebView?
    private(set) var isReady = false
    private var pendingData: RepoLandingData?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        isReady = false
        pendingData = nil
    }

    var onReady: (() -> Void)?
    var onSelectWorkspace: ((String) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onOpenTerminal: (() -> Void)?
    var onArchiveWorkspace: ((String) -> Void)?
    var onOpenInEditor: ((String) -> Void)?
    var onRevealInFinder: ((String) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
            let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else { return }

        switch action {
        case "ready":
            isReady = true
            if let pending = pendingData {
                pushData(pending)
                pendingData = nil
            }
            onReady?()
        case "selectWorkspace":
            if let id = body["id"] as? String { onSelectWorkspace?(id) }
        case "createWorkspace":
            onCreateWorkspace?()
        case "openTerminal":
            onOpenTerminal?()
        case "archiveWorkspace":
            if let id = body["id"] as? String { onArchiveWorkspace?(id) }
        case "openInEditor":
            if let id = body["id"] as? String { onOpenInEditor?(id) }
        case "revealInFinder":
            if let id = body["id"] as? String { onRevealInFinder?(id) }
        default:
            break
        }
    }

    func pushData(_ data: RepoLandingData) {
        guard let wv = webView else {
            pendingData = data
            return
        }
        guard isReady else {
            pendingData = data
            return
        }
        guard let jsonData = try? JSONEncoder().encode(data),
            let json = String(data: jsonData, encoding: .utf8)
        else { return }
        wv.evaluateJavaScript("window.RepoLanding?.onData(\(json))") { _, _ in }
    }
}

// MARK: - Bridge Data Types

struct RepoLandingData: Codable {
    let repo: RepoInfo
    let workspaces: [WorkspaceInfo]

    struct RepoInfo: Codable {
        let name: String
        let localPath: String
        let remoteURL: String?
    }

    struct WorkspaceInfo: Codable {
        let id: String
        let name: String
        let branch: String?
        let path: String
        let status: String
        let lastAccessedAt: Double
        let isAgentRunning: Bool
        let agentName: String?
        let processes: [ProcessInfo]

        struct ProcessInfo: Codable {
            let displayName: String
            let isKnownAgent: Bool
        }
    }
}
