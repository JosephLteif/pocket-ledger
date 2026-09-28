import SwiftUI

@main
struct PocketLedgerWatchApp: App {
    @StateObject private var store = WatchLedgerStore()

    var body: some Scene {
        WindowGroup {
            WatchHomeView(store: store)
                .task {
                    store.activate()
                }
        }
    }
}
