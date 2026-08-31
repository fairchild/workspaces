// App entry for the WorkSpaces mobile variant: one paired node today,
// rendered through the node's own web-next surface over the tailnet.
import SwiftUI

@main
struct WorkSpacesMobileApp: App {
    @StateObject private var store = NodeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
