import XCTest

final class DesignReviewScreenshots: XCTestCase {
    @MainActor
    func testCapturePrimaryNavigationAndEditors() {
        let app = XCUIApplication()
        app.launchArguments.append("-DesignReviewMode")
        app.launch()

        selectTab("tab-overview", title: "Home", app: app)
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

        app.buttons["add-transaction-button"].tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        capture("05-expense-editor", app: app)
        app.buttons["Cancel"].tap()

        app.buttons["more-transaction-actions"].tap()
        app.buttons["Transfer"].tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        capture("06-transfer-editor", app: app)
        app.buttons["Cancel"].tap()

        app.buttons["more-transaction-actions"].tap()
        app.buttons["Loan"].tap()
        XCTAssertTrue(app.navigationBars["New loan"].waitForExistence(timeout: 10))
        capture("07-loan-editor", app: app)
        app.buttons["Cancel"].tap()

        app.buttons["more-transaction-actions"].tap()
        app.buttons["Physical asset purchase"].tap()
        XCTAssertTrue(app.navigationBars["Physical asset purchase"].waitForExistence(timeout: 10))
        capture("08-physical-asset-account-picker", app: app)
        app.buttons["Gold holdings"].tap()
        XCTAssertTrue(app.navigationBars["Add gold purchase"].waitForExistence(timeout: 10))
        capture("09-gold-purchase-editor", app: app)
        app.buttons["Gold karat presets"].tap()
        capture("09a-gold-karat-menu", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        app.buttons["Cancel"].tap()

        app.buttons["more-transaction-actions"].tap()
        app.buttons["Investment purchase"].tap()
        XCTAssertTrue(app.navigationBars["Investment purchase"].waitForExistence(timeout: 10))
        capture("10-investment-account-picker", app: app)
        app.buttons["Brokerage"].tap()
        XCTAssertTrue(app.navigationBars["Investment purchase"].waitForExistence(timeout: 10))
        capture("11-investment-purchase-editor", app: app)
        app.buttons["Cancel"].tap()

        app.buttons["more-transaction-actions"].tap()
        app.buttons["Scheduled"].tap()
        XCTAssertTrue(app.navigationBars["Schedule transaction"].waitForExistence(timeout: 10))
        capture("12-scheduled-transaction-editor", app: app)
        app.buttons["Cancel"].tap()

        selectTab("tab-search", title: "Search", app: app)
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        capture("13-search", app: app)
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("groceries")
        app.keyboards.buttons["Search"].tap()
        capture("13a-search-results", app: app)

        selectTab("tab-transactions", title: "Transactions", app: app)
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        capture("14-transactions", app: app)
        app.buttons["transaction-filters"].tap()
        XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 10))
        capture("15-transaction-filters", app: app)
        app.buttons["Done"].tap()

        selectTab("tab-accounts", title: "Accounts", app: app)
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))
        capture("16-accounts", app: app)
        app.staticTexts["Everyday Checking"].tap()
        XCTAssertTrue(app.navigationBars["Everyday Checking"].waitForExistence(timeout: 10))
        capture("17-account-detail", app: app)

        app.buttons["Edit account"].tap()
        XCTAssertTrue(app.navigationBars["Edit account"].waitForExistence(timeout: 10))
        capture("18-account-editor", app: app)
        app.buttons["Cancel"].tap()

        app.buttons["Adjust current balance"].tap()
        XCTAssertTrue(app.navigationBars["Edit balance"].waitForExistence(timeout: 10))
        capture("19-account-balance-editor", app: app)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testCaptureMoreDestinations() {
        let app = XCUIApplication()
        app.launchArguments.append("-DesignReviewMode")
        app.launch()
        selectTab("tab-more", title: "More", app: app)
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        capture("20-more", app: app)

        openMoreDestination("Metrics", navigationTitle: "Metrics", app: app)
        capture("21-metrics", app: app)
        app.buttons["metrics-secondary-filters"].tap()
        XCTAssertTrue(app.navigationBars["Breakdown"].waitForExistence(timeout: 10))
        capture("22-metrics-breakdown", app: app)
        app.buttons["Done"].tap()
        returnToMore(app)

        openMoreDestination("Savings goals", navigationTitle: "Savings goals", app: app)
        capture("23-savings-goals", app: app)
        app.buttons["Add savings goal"].tap()
        XCTAssertTrue(app.navigationBars["New savings goal"].waitForExistence(timeout: 10))
        capture("24-savings-goal-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)
        capture("25-more-planning", app: app)

        openMoreDestination("Loans", navigationTitle: "Loans", app: app)
        capture("26-loans", app: app)
        let seededLoan = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alex Morgan")).firstMatch
        XCTAssertTrue(seededLoan.waitForExistence(timeout: 10))
        seededLoan.tap()
        XCTAssertTrue(app.navigationBars["Alex Morgan"].waitForExistence(timeout: 10))
        capture("27-loan-detail", app: app)
        app.buttons["Record collection"].tap()
        XCTAssertTrue(app.navigationBars["Record collection"].waitForExistence(timeout: 10))
        capture("28-loan-collection-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)

        openMoreDestination("Budgets", navigationTitle: "Budgets", app: app)
        capture("29-budgets", app: app)
        app.buttons["Add budget"].tap()
        XCTAssertTrue(app.navigationBars["New budget"].waitForExistence(timeout: 10))
        capture("30-budget-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)

        openMoreDestination("Scheduled & subscriptions", navigationTitle: "Scheduled", app: app)
        capture("31-scheduled-transactions", app: app)
        app.buttons["Add scheduled transaction"].tap()
        XCTAssertTrue(app.navigationBars["Schedule transaction"].waitForExistence(timeout: 10))
        capture("32-scheduled-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)

        openMoreDestination("Templates", navigationTitle: "Templates", app: app)
        capture("33-templates", app: app)
        app.buttons["Create template"].tap()
        XCTAssertTrue(app.navigationBars["New template"].waitForExistence(timeout: 10))
        capture("34-template-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)

        openMoreDestination("Categories", navigationTitle: "Categories", app: app)
        capture("35-categories", app: app)
        app.buttons["Add category"].tap()
        XCTAssertTrue(app.navigationBars["New category"].waitForExistence(timeout: 10))
        capture("36-category-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)
        capture("37-more-organization", app: app)

        openMoreDestination("Exchange rates", navigationTitle: "Exchange rates", app: app)
        capture("38-exchange-rates", app: app)
        app.buttons["Add exchange rate"].tap()
        XCTAssertTrue(app.navigationBars["Add exchange rate"].waitForExistence(timeout: 10))
        capture("39-exchange-rate-editor", app: app)
        app.buttons["Cancel"].tap()
        returnToMore(app)

        openMoreDestination("Import & Backup", navigationTitle: "Import & Backup", app: app)
        capture("40-import-and-backup", app: app)
        returnToMore(app)

        openMoreDestination("Settings", navigationTitle: "Settings", app: app)
        capture("41-settings", app: app)
        let privacyPolicy = app.buttons["Privacy Policy"].firstMatch
        for _ in 0..<5 where !privacyPolicy.isHittable { app.swipeUp() }
        XCTAssertTrue(privacyPolicy.waitForExistence(timeout: 10))
        privacyPolicy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 10))
        capture("42-privacy-policy", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        returnToMore(app)
        capture("43-more-data-and-security", app: app)
    }

    @MainActor
    func testCaptureImportWizardScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["-DesignReviewMode", "-ImportWizardUITest"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Source & mapping"].waitForExistence(timeout: 30))
        capture("44-import-source-mapping", app: app)
        app.buttons["importWizard.next"].tap()
        XCTAssertTrue(app.navigationBars["Defaults"].waitForExistence(timeout: 10))
        capture("45-import-defaults", app: app)
        app.buttons["importWizard.next"].tap()
        XCTAssertTrue(app.navigationBars["Accounts & categories"].waitForExistence(timeout: 30))
        capture("46-import-accounts-and-categories", app: app)
        app.buttons["importWizard.next"].tap()
        XCTAssertTrue(app.navigationBars["Review & import"].waitForExistence(timeout: 10))
        capture("47-import-review", app: app)
    }

    @MainActor
    private func openMoreDestination(_ title: String, navigationTitle: String, app: XCUIApplication) {
        let destination = app.buttons[title].firstMatch
        for _ in 0..<8 {
            if destination.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(destination.isHittable, "More destination is not tappable: \(title)")
        destination.tap()
        XCTAssertTrue(app.navigationBars[navigationTitle].waitForExistence(timeout: 10))
    }

    @MainActor
    private func returnToMore(_ app: XCUIApplication) {
        for _ in 0..<3 where !app.navigationBars["More"].exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
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
