//
//  EditorSurfaceStore.swift
//  WorkspaceManager
//
//  Owns the WKWebView that hosts the embedded CodeMirror editor bundle and brokers the
//  bridge messages. Loads the local DiffEditorWeb bundle (read access scoped to the bundle
//  dir — file contents arrive over the bridge, never via file://). A weak script-message
//  proxy keeps WKUserContentController's strong retain from leaking the store.
//

import AppKit
import Foundation
import WebKit

@MainActor
final class EditorSurfaceStore: ObservableObject {
    @Published private(set) var isDirty = false
    /// Increments each time the editor requests a save (Cmd+S inside the webview).
    @Published private(set) var saveRequestID = 0

    private var webView: WKWebView?
    private var isReady = false
    private var pendingInit: EditorInitPayload?

    private static let messageName = "editor"

    func makeWebView() -> WKWebView {
        if let webView { return webView }

        let controller = WKUserContentController()
        controller.add(WeakScriptMessageProxy(target: self), name: Self.messageName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
        loadBundle(into: webView)
        return webView
    }

    private func loadBundle(into webView: WKWebView) {
        guard let dir = Bundle.module.url(forResource: "DiffEditorWeb", withExtension: nil) else {
            EditorDiagnostics.log("bundle directory missing")
            return
        }
        let index = dir.appendingPathComponent("index.html")
        webView.loadFileURL(index, allowingReadAccessTo: dir)
    }

    /// Push (or queue) an init payload. Safe to call before the bundle reports `ready`.
    func load(_ payload: EditorInitPayload) {
        pendingInit = payload
        isDirty = false
        flushPendingInitIfReady()
    }

    func reload(_ payload: EditorInitPayload) {
        load(payload)
    }

    func setTheme(_ theme: EditorThemePayload) {
        guard let webView else { return }
        evaluate("window.__editorHost.setTheme", payload: theme, in: webView)
    }

    func markSaved() {
        webView?.evaluateJavaScript("window.__editorHost.markSaved()")
    }

    /// The current document text, fetched from the live editor.
    func currentDocument() async -> String? {
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.__editorHost.getDoc()",
                arguments: [:],
                contentWorld: .page
            )
            return result as? String
        } catch {
            EditorDiagnostics.log("getDoc failed: \(error.localizedDescription)")
            return nil
        }
    }

    func tearDown() {
        guard let webView else { return }
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        self.webView = nil
        isReady = false
        pendingInit = nil
    }

    fileprivate func receive(_ message: EditorInboundMessage) {
        switch message {
        case .ready:
            isReady = true
            flushPendingInitIfReady()
        case .dirty(let value):
            isDirty = value
        case .save:
            saveRequestID += 1
        case .log(let text):
            EditorDiagnostics.log("js: \(text)")
        case .unknown(let type):
            EditorDiagnostics.log("unknown message: \(type)")
        }
    }

    private func flushPendingInitIfReady() {
        guard isReady, let payload = pendingInit, let webView else { return }
        pendingInit = nil
        evaluate("window.__editorHost.init", payload: payload, in: webView)
    }

    private func evaluate<Payload: Encodable>(_ function: String, payload: Payload, in webView: WKWebView) {
        guard let data = try? JSONEncoder().encode(payload),
            let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("\(function)(\(json))")
    }
}

/// Forwards script messages to the store without the content controller retaining it.
@MainActor
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: EditorSurfaceStore?

    init(target: EditorSurfaceStore) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.receive(EditorInboundMessage(body: message.body))
    }
}
