// First-run pairing: base URL + token, validated against the node's public
// /api/healthz before anything is stored. QR pairing (url + token + cert
// fingerprint) replaces the paste flow later in #1457.
import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var store: NodeStore
    @State private var urlText = ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                if QRScannerView.isSupported {
                    Section {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan QR from your Mac", systemImage: "qrcode.viewfinder")
                        }
                    } footer: {
                        Text("WorkSpaces on the Mac shows a pairing QR carrying its address and token.")
                    }
                }
                Section {
                    TextField("https://mac.tailxxxx.ts.net", text: $urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Node address")
                } footer: {
                    Text("The tailscale serve URL of a machine running WorkSpaces.")
                }
                Section("Access token") {
                    SecureField("Paste the node's sign-in token", text: $token)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button(action: connect) {
                        if checking {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(checking || urlText.isEmpty || token.isEmpty)
                }
            }
            .navigationTitle("Pair a node")
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScannerView(onScan: handleScanned)
                        .ignoresSafeArea()
                        .navigationTitle("Scan pairing QR")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Cancel") { scanning = false }
                            }
                        }
                }
            }
        }
    }

    /// A pairing QR carries the node's sign-in URL; base and token fall out
    /// of it. Anything else scanned is reported, never silently ignored.
    private func handleScanned(_ payload: String) {
        scanning = false
        guard var components = URLComponents(string: payload),
            components.scheme == "https" || components.scheme == "http",
            components.host != nil,
            let scannedToken = components.queryItems?
                .first(where: { $0.name == "token" })?.value,
            !scannedToken.isEmpty
        else {
            error = "That QR doesn't look like a WorkSpaces pairing code."
            return
        }
        let port = components.port.map { ":\($0)" } ?? ""
        urlText = "\(components.scheme!)://\(components.host!)\(port)"
        token = scannedToken
        connect()
    }

    private func connect() {
        guard let url = normalizedBaseURL() else {
            error = "That doesn't look like an https URL."
            return
        }
        let candidate = Node(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: candidate.healthzURL())
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                    let body = try? JSONDecoder().decode(Healthz.self, from: data), body.ok
                else {
                    error = "The node answered, but not like a WorkSpaces node."
                    return
                }
                store.save(candidate)
                await Self.postAck(candidate)
            } catch {
                self.error = "Couldn't reach the node. On the tailnet? \(error.localizedDescription)"
            }
        }
    }

    /// The pairing handshake: prove token possession so the node's desktop
    /// pairing window can flip its QR into a confirmation. Best-effort —
    /// the pairing stands even if the ack never lands.
    private static func postAck(_ node: Node) async {
        var components = URLComponents(url: node.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/pairing/ack"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": node.token])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// https everywhere, with one sanctioned exception: plain http to
    /// loopback (simulator/dev), mirroring the server's own Host-gate rule.
    private func normalizedBaseURL() -> URL? {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://\(text)" }
        guard let url = URL(string: text), let host = url.host else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && loopback) else {
            return nil
        }
        return url
    }

    private struct Healthz: Decodable {
        let ok: Bool
    }
}
