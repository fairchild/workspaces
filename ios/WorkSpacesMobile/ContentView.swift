// Root switch: unpaired shows the pairing form, paired shows the node's
// sessions surface with minimal chrome (reload, unpair) and an honest
// recovery path when the node stops accepting this device's token.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: NodeStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var reloadToken = 0
    @State private var tokenRejected = false

    var body: some View {
        if let node = store.node {
            NavigationStack {
                SessionsWebView(
                    node: node,
                    reloadToken: $reloadToken,
                    onTokenRejected: { tokenRejected = true }
                )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(node.host)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Reload") { reloadToken += 1 }
                            Button("Unpair node", role: .destructive) {
                                store.unpair()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .alert("Pairing no longer accepted", isPresented: $tokenRejected) {
                    Button("Unpair", role: .destructive) { store.unpair() }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text(
                        "\(node.host) rejected this device's token — it was most likely rotated on the Mac. Unpair and scan a fresh QR to reconnect."
                    )
                }
                // A token rotated while the page sat open only shows up as 401s
                // on the page's own fetches, which never navigate — so ask the
                // node directly whenever we come back to the foreground.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        if await Self.nodeRejectsToken(node) { tokenRejected = true }
                    }
                }
            }
        } else {
            PairingView()
        }
    }

    /// Only an explicit 401 counts as rejection: an unreachable node is a
    /// network problem, and a 404 is an older node without the pairing routes.
    private static func nodeRejectsToken(_ node: Node) async -> Bool {
        var request = URLRequest(url: node.pairingAckURL())
        request.setValue("Bearer \(node.token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 401
    }
}
