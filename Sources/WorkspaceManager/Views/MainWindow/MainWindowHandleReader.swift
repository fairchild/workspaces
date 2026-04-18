import AppKit
import SwiftUI

struct MainWindowHandleReader: NSViewRepresentable {
    let onResolveWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            Task { @MainActor in
                onResolveWindow(window)
            }
        }
    }
}
