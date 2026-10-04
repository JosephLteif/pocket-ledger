import XCTest
@testable import PocketLedger

final class FreemiumAccessTests: XCTestCase {
    @MainActor
    func testFreeAccountLimitAndProAccountTypes() {
        XCTAssertTrue(PocketLedgerTierPolicy.canCreateAccount(type: .cash, activeCount: 4, hasPro: false))
        XCTAssertFalse(PocketLedgerTierPolicy.canCreateAccount(type: .bankAccount, activeCount: 5, hasPro: false))
        XCTAssertFalse(PocketLedgerTierPolicy.canCreateAccount(type: .investment, activeCount: 0, hasPro: false))
        XCTAssertTrue(PocketLedgerTierPolicy.canCreateAccount(type: .investment, activeCount: 5, hasPro: true))
    }

    @MainActor
    func testScheduleLimitOnlyAppliesToEnabledSchedules() {
        XCTAssertTrue(PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: true,
            isAlreadyEnabled: false,
            enabledCount: 9,
            hasPro: false
        ))
        XCTAssertFalse(PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: true,
            isAlreadyEnabled: false,
            enabledCount: 10,
            hasPro: false
        ))
        XCTAssertTrue(PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: true,
            isAlreadyEnabled: false,
            enabledCount: 10,
            hasPro: true
        ))
        XCTAssertTrue(PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: false,
            isAlreadyEnabled: false,
            enabledCount: 10,
            hasPro: false
        ))
        XCTAssertTrue(PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: true,
            isAlreadyEnabled: true,
            enabledCount: 10,
            hasPro: false
        ))
    }

    @MainActor
    func testBudgetLimitAndRolloverAccess() {
        XCTAssertTrue(PocketLedgerTierPolicy.canCreateBudget(count: 4, hasPro: false))
        XCTAssertFalse(PocketLedgerTierPolicy.canCreateBudget(count: 5, hasPro: false))
        XCTAssertTrue(PocketLedgerTierPolicy.canCreateBudget(count: 5, hasPro: true))
        XCTAssertFalse(PocketLedgerTierPolicy.canUseRollover(isAlreadyEnabled: false, hasPro: false))
        XCTAssertTrue(PocketLedgerTierPolicy.canUseRollover(isAlreadyEnabled: true, hasPro: false))
        XCTAssertTrue(PocketLedgerTierPolicy.canUseRollover(isAlreadyEnabled: false, hasPro: true))
    }

    @MainActor
    func testFreeMetricsHistoryUsesLatestTwelveMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let october2025 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 10, day: 1)))
        let november2025 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 11, day: 1)))
        let currentYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let previousYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))

        XCTAssertFalse(PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: october2025,
            isCalendarYear: false,
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: november2025,
            isCalendarYear: false,
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: currentYear,
            isCalendarYear: true,
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: previousYear,
            isCalendarYear: true,
            now: now,
            calendar: calendar
        ))
    }

    @MainActor
    func testLedgerStoreRejectsNewAccountsButPreservesImportedAccounts() throws {
        let accountData = financeData(accountCount: 5)
        let (store, _) = try makeStore(with: accountData)
        XCTAssertFalse(store.addAccount(Account(
            name: "Extra",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )))
        XCTAssertEqual(store.activeAccounts.count, 5)
        XCTAssertEqual(store.proAccessRequired, .accounts)
        var renamed = try XCTUnwrap(store.activeAccounts.first)
        renamed.name = "Updated account"
        XCTAssertTrue(store.updateAccount(renamed))

        var imported = FinanceData.empty
        imported.accounts = (0..<7).map { index in
            Account(
                name: "Imported \(index)",
                type: .cash,
                currency: .usd,
                openingBalance: Money(currency: .usd, minorUnits: 0)
            )
        }
        XCTAssertTrue(store.replaceData(imported))
        XCTAssertEqual(store.activeAccounts.count, 7)
    }

    @MainActor
    func testArchivingFreesAccountSlotButReactivationIsLimited() throws {
        let (store, _) = try makeStore(with: financeData(accountCount: 5))
        let archivedAccountID = try XCTUnwrap(store.activeAccounts.first?.id)

        XCTAssertTrue(store.setAccountArchived(accountID: archivedAccountID, isArchived: true))
        XCTAssertEqual(store.activeAccounts.count, 4)
        XCTAssertTrue(store.addAccount(Account(
            name: "Replacement",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )))
        XCTAssertFalse(store.setAccountArchived(accountID: archivedAccountID, isArchived: false))
        XCTAssertEqual(store.proAccessRequired, .accounts)
        XCTAssertTrue(store.data.accounts.first(where: { $0.id == archivedAccountID })?.isArchived == true)
    }

    @MainActor
    func testArchivedImportedPremiumAccountNeedsProToReactivate() throws {
        var data = financeData(accountCount: 0)
        data.accounts = [Account(
            name: "Imported investment",
            type: .investment,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0),
            isArchived: true
        )]
        let (store, _) = try makeStore(with: data)

        XCTAssertFalse(store.setAccountArchived(
            accountID: try XCTUnwrap(store.data.accounts.first?.id),
            isArchived: false
        ))
        XCTAssertEqual(store.proAccessRequired, .accountTypes)
        XCTAssertTrue(store.data.accounts[0].isArchived)
    }

    @MainActor
    func testLedgerStoreCountsOnlyEnabledSchedulesAndAllowsPausing() throws {
        var data = financeData(accountCount: 1)
        let account = try XCTUnwrap(data.accounts.first)
        let category = LedgerCategory(name: "Bills")
        data.categories = [category]
        data.scheduledTransactions = (0..<10).map { index in
            makeSchedule(index: index, account: account, category: category)
        }
        let (store, _) = try makeStore(with: data)

        let extra = makeSchedule(index: 10, account: account, category: category)
        XCTAssertFalse(store.addScheduledTransaction(extra))
        XCTAssertEqual(store.proAccessRequired, .schedules)
        XCTAssertEqual(store.data.scheduledTransactions.filter(\.isEnabled).count, 10)
        var edited = try XCTUnwrap(store.data.scheduledTransactions.first)
        edited.note = "Updated schedule"
        XCTAssertTrue(store.updateScheduledTransaction(edited))

        XCTAssertTrue(store.setScheduledTransactionEnabled(
            id: try XCTUnwrap(store.data.scheduledTransactions.first?.id),
            isEnabled: false
        ))
        XCTAssertEqual(store.data.scheduledTransactions.filter(\.isEnabled).count, 9)
        XCTAssertTrue(store.addScheduledTransaction(extra))
        XCTAssertEqual(store.data.scheduledTransactions.filter(\.isEnabled).count, 10)
        let pausedScheduleID = try XCTUnwrap(
            store.data.scheduledTransactions.first(where: { !$0.isEnabled })?.id
        )
        XCTAssertFalse(store.setScheduledTransactionEnabled(
            id: pausedScheduleID,
            isEnabled: true
        ))
        XCTAssertEqual(store.proAccessRequired, .schedules)
    }

    @MainActor
    func testLedgerStoreEnforcesBudgetAndRolloverLimits() throws {
        var data = financeData(accountCount: 1)
        let categories = (0..<5).map { LedgerCategory(name: "Category \($0)") }
        data.categories = categories
        data.budgets = categories.enumerated().map { index, category in
            LedgerBudget(
                categoryID: category.id,
                currency: .usd,
                monthlyLimit: Money(currency: .usd, minorUnits: Int64(index + 1))
            )
        }
        let (store, _) = try makeStore(with: data)

        XCTAssertFalse(store.upsertBudget(LedgerBudget(
            categoryID: categories[0].id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 1)
        )))
        XCTAssertEqual(store.proAccessRequired, .budgets)
        var editedBudget = try XCTUnwrap(store.data.budgets.first)
        editedBudget.monthlyLimit = Money(currency: .usd, minorUnits: 10)
        XCTAssertTrue(store.upsertBudget(editedBudget))

        var rolloverBudget = try XCTUnwrap(store.data.budgets.first)
        rolloverBudget.rollover = true
        XCTAssertFalse(store.upsertBudget(rolloverBudget))
        XCTAssertEqual(store.proAccessRequired, .budgetRollover)

        let firstBudgetID = try XCTUnwrap(store.data.budgets.first?.id)
        XCTAssertTrue(store.deleteBudget(id: firstBudgetID))
        XCTAssertTrue(store.upsertBudget(LedgerBudget(
            categoryID: categories[0].id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 1)
        )))
    }

    @MainActor
    func testProCanExceedEveryFreeLimit() throws {
        var data = financeData(accountCount: 5)
        let account = try XCTUnwrap(data.accounts.first)
        let categories = (0..<6).map { LedgerCategory(name: "Category \($0)") }
        data.categories = categories
        data.budgets = categories.prefix(5).map { category in
            LedgerBudget(
                categoryID: category.id,
                currency: .usd,
                monthlyLimit: Money(currency: .usd, minorUnits: 100)
            )
        }
        data.scheduledTransactions = (0..<10).map { index in
            makeSchedule(index: index, account: account, category: categories[0])
        }
        let (store, _) = try makeStore(with: data, hasProAccess: true)

        XCTAssertTrue(store.addAccount(Account(
            name: "Investment",
            type: .investment,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )))
        XCTAssertTrue(store.addScheduledTransaction(
            makeSchedule(index: 10, account: account, category: categories[0])
        ))
        XCTAssertTrue(store.upsertBudget(LedgerBudget(
            categoryID: categories[5].id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 100)
        )))
    }

    @MainActor
    private func makeStore(with data: FinanceData, hasProAccess: Bool = false) throws -> (LedgerStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("ledger.sqlite")
        let storage = FinanceStorage(databaseURL: databaseURL)
        guard storage.save(data) else { throw CocoaError(.fileWriteUnknown) }
        return (LedgerStore(storage: storage, hasProAccess: { hasProAccess }), databaseURL)
    }

    private func financeData(accountCount: Int) -> FinanceData {
        var data = FinanceData.empty
        data.accounts = (0..<accountCount).map { index in
            Account(
                name: "Account \(index)",
                type: .cash,
                currency: .usd,
                openingBalance: Money(currency: .usd, minorUnits: 0)
            )
        }
        return data
    }

    private func makeSchedule(index: Int, account: Account, category: LedgerCategory) -> ScheduledTransaction {
        ScheduledTransaction(
            nextRunDate: Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now,
            frequency: .monthly,
            note: "Bill \(index)",
            kind: .expense,
            categoryID: category.id,
            outflows: [MoneyMovement(
                accountID: account.id,
                money: Money(currency: .usd, minorUnits: 100)
            )],
            inflows: []
        )
    }
}
