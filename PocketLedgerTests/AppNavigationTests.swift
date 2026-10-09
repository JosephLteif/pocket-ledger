import XCTest
@testable import PocketLedger

final class AppNavigationTests: XCTestCase {
    func testSupportedPocketLedgerRoutesSelectExpectedTabs() {
        XCTAssertEqual(
            AppTab(url: URL(string: "pocketledger://overview")!),
            .overview
        )
        XCTAssertEqual(
            AppTab(url: URL(string: "pocketledger://accounts")!),
            .accounts
        )
        XCTAssertEqual(
            AppTab(url: URL(string: "pocketledger://transactions")!),
            .transactions
        )
    }

    func testExternalAndUnknownRoutesAreIgnored() {
        XCTAssertNil(AppTab(url: URL(string: "https://example.com")!))
        XCTAssertNil(AppTab(url: URL(string: "pocketledger://metrics")!))
    }

    func testMainTabOrderAndHomeLabel() {
        XCTAssertEqual(AppTab.tabBarOrder, [.overview, .transactions, .accounts, .metrics, .more])
        XCTAssertEqual(AppTab.overview.title, "Home")
        XCTAssertEqual(AppTab.metrics.title, "Insights")
    }

    func testRestoredSelectionSupportsInsightsAndRetiresSearchTab() {
        XCTAssertEqual(AppTab.restoredTab(rawValue: "metrics"), .metrics)
        XCTAssertEqual(AppTab.restoredTab(rawValue: "search"), .overview)
        XCTAssertEqual(AppTab.restoredTab(rawValue: "unknown"), .overview)
        XCTAssertEqual(AppTab.restoredTab(rawValue: "accounts"), .accounts)
    }
}
