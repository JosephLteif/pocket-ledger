import XCTest
@testable import PocketLedger

final class DashboardPreferencesTests: XCTestCase {
    func testDefaultsPrioritizeDailySummaryWidgets() {
        XCTAssertEqual(
            DashboardPreferences.defaultPreferences.order,
            [
                .balance,
                .monthSummary,
                .recentActivity,
                .attention,
                .physicalAssetGain,
                .accounts,
                .loans,
                .upcoming,
                .cashFlow,
                .budgetPulse,
                .storageStatus
            ]
        )
        XCTAssertEqual(
            DashboardPreferences.defaultPreferences.enabledWidgets,
            [.balance, .monthSummary, .recentActivity, .attention, .physicalAssetGain]
        )
    }

    func testMissingAndDuplicateWidgetsAreRepaired() {
        let preferences = DashboardPreferences(order: [.recentActivity, .recentActivity])

        XCTAssertEqual(preferences.order.count, DashboardWidget.allCases.count)
        XCTAssertEqual(preferences.order.first, .recentActivity)
        XCTAssertEqual(Set(preferences.order), Set(DashboardWidget.allCases))
    }

    func testVisibilityAndOrderRoundTripThroughUserDefaults() throws {
        let suiteName = "DashboardPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences = DashboardPreferences()
        preferences.setEnabled(false, for: .cashFlow)
        preferences.move(from: IndexSet(integer: 0), to: preferences.order.count)
        preferences.save(to: defaults)

        let reloaded = DashboardPreferences.load(from: defaults)
        XCTAssertEqual(reloaded.order.last, .balance)
        XCTAssertFalse(reloaded.enabledWidgets.contains(.cashFlow))
        XCTAssertEqual(reloaded.disabledWidgets, [.cashFlow])
    }
}
