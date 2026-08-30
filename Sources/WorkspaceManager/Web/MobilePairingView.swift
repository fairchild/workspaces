//
//  MobilePairingView.swift
//  WorkspaceManager
//
//  The "Pair Mobile Device" window: starts the embedded web-next child if
//  needed, rebases its token-bearing sign-in URL onto the Mac's tailnet
//  origin, and renders it as a QR the mobile variant scans (#1457). The QR
//  carries the bearer token — rendered on demand, never persisted or logged.
//

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WorkspaceManagerCore

@MainActor
final class MobilePairingModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case ready(qr: NSImage, origin: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting

    private let server: any WebNextServerServiceProtocol

    init(server: any WebNextServerServiceProtocol) {
        self.server = server
    }

    func activate() async {
        phase = .starting
        guard let origin = TailnetIdentity.httpsOrigin() else {
            phase = .failed("No tailnet detected — is Tailscale installed, running, and connected?")
            return
        }
        await server.start()
        switch await awaitTerminalState() {
        case .ready:
            break
        case .failed(let reason):
            phase = .failed(reason)
            return
        case .idle, .starting:
            phase = .failed("The embedded web-next server did not reach a ready state.")
            return
        }
        guard
            let localURL = await server.signInURL(redirect: "/"),
            let pairURL = Self.rebase(localURL, ontoOrigin: origin),
            let qr = Self.qrImage(for: pairURL.absoluteString)
        else {
            phase = .failed("The sign-in token is not available yet — try again in a moment.")
            return
        }
        phase = .ready(qr: qr, origin: origin)
    }

    /// Mirrors EmbeddedWebNextModel's backstop: outlast the service's own
    /// 180s cold-build readiness budget so the window never gives up first.
    private func awaitTerminalState() async -> WebNextServerState {
        var state = await server.state
        var elapsed: TimeInterval = 0
        let pollInterval: TimeInterval = 0.15
        let maxWait: TimeInterval = 210
        while case .starting = state, elapsed < maxWait, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            elapsed += pollInterval
            state = await server.state
        }
        return state
    }

    /// The loopback sign-in URL with scheme/host/port swapped for the tailnet
    /// origin — path and token query survive untouched.
    static func rebase(_ url: URL, ontoOrigin origin: String) -> URL? {
        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let originURL = URL(string: origin),
            let host = originURL.host
        else { return nil }
        components.scheme = originURL.scheme
        components.host = host
        components.port = originURL.port
        return components.url
    }

    static func qrImage(for payload: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: scaled.extent.width, height: scaled.extent.height)
        )
    }
}

struct MobilePairingView: View {
    @StateObject private var model: MobilePairingModel

    init(server: any WebNextServerServiceProtocol) {
        _model = StateObject(wrappedValue: MobilePairingModel(server: server))
    }

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .starting:
                ProgressView("Starting the embedded server…")
                    .frame(width: 280, height: 280)
            case .ready(let qr, let origin):
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 280, height: 280)
                    .accessibilityLabel("Mobile pairing QR code")
                Text(origin)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan from the WorkSpaces app on your phone (both on the tailnet).")
                    Text("The code carries this Mac's sign-in token — treat it like a password.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                serveHint
            case .failed(let reason):
                Image(systemName: "qrcode")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
                    .frame(width: 280, height: 120)
                Text(reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button("Try Again") {
                    Task { await model.activate() }
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .task { await model.activate() }
    }

    /// tailscale serve is one-time node state, deliberately not mutated by the
    /// app — surface the exact command instead.
    private var serveHint: some View {
        HStack(spacing: 6) {
            Text("One-time on this Mac:")
            Text(Self.serveCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.serveCommand, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the tailscale serve command")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static let serveCommand = "tailscale serve --bg \(WebNextServerSettings.port)"
}
