import XCTest

final class DesignReviewScreenshots: XCTestCase {
    @MainActor
    func testCaptureDesignReviewScreenshots() {
        let app = XCUIApplication()
        app.launchArguments.append("-DesignReviewMode")
        app.launch()

        XCTAssertTrue(app.buttons["dashboard-customize"].waitForExistence(timeout: 30))
        capture("01-home", app: app)

        app.buttons["dashboard-customize"].tap()
        XCTAssertTrue(app.navigationBars["Customize dashboard"].waitForExistence(timeout: 10))
        capture("02-dashboard-customization", app: app)
        app.buttons["Done"].tap()

        app.buttons["more-transaction-actions"].tap()
        XCTAssertTrue(app.buttons["Income"].waitForExistence(timeout: 10))
        capture("03-transaction-actions-menu", app: app)
        app.buttons["Income"].tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        capture("04-income-editor", app: app)
        app.buttons["Cancel"].tap()

        selectTab("tab-transactions", title: "Transactions", app: app)
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        capture("05-transactions", app: app)
        app.buttons["transaction-filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 10))
        capture("06-transaction-filters", app: app)
        app.buttons["Done"].tap()

        selectTab("tab-accounts", title: "Accounts", app: app)
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))
        capture("07-accounts", app: app)
        app.staticTexts["Everyday Checking"].tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 10))
        capture("08-account-detail", app: app)

        selectTab("tab-more", title: "More", app: app)
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        capture("09-more", app: app)
        app.buttons["Metrics"].tap()
        XCTAssertTrue(app.navigationBars["Metrics"].waitForExistence(timeout: 10))
        capture("10-metrics", app: app)
    }

    @MainActor
    private func selectTab(_ identifier: String, title: String, app: XCUIApplication) {
        let tab = app.buttons[identifier]
        if tab.exists {
            tab.tap()
        } else {
            app.tabBars.buttons[title].tap()
        }
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
