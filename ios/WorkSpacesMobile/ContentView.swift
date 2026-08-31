// Root switch: unpaired shows the pairing form, paired shows the node's
// sessions surface with minimal chrome (reload, unpair).
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: NodeStore
    @State private var reloadToken = 0

    var body: some View {
        if let node = store.node {
            NavigationStack {
                SessionsWebView(node: node, reloadToken: $reloadToken)
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
            }
        } else {
            PairingView()
        }
    }
}
