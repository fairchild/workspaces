// Root switch: unpaired shows the pairing form, paired shows the node's
// sessions surface with minimal chrome (reload, unpair) and an honest
// recovery path when the node stops accepting this device's token.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: NodeStore
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
            }
        } else {
            PairingView()
        }
    }
}
