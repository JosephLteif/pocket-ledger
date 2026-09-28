import SwiftUI

@main
struct PocketLedgerApp: App {
    init() {
        NotificationService.configureForegroundPresentation()
        PocketLedgerShortcuts.updateAppShortcutParameters()
        WatchConnectivityService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
