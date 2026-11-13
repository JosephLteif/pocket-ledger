import Foundation
import SwiftUI

@main
struct PocketLedgerApp: App {
    init() {
        NotificationService.configureForegroundPresentation()
        PocketLedgerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
