import XCTest
@testable import PocketLedger

final class UIConsistencyTests: XCTestCase {
    @MainActor
    func testBulkAccountChangeReturnsOnlyEligibleIDs() throws {
        let data = makeLedger()
        let (store, _) = try makeStore(with: data)
        let selected = Set(data.transactions.map(\.id)).union([UUID()])
        let eligible = Set(data.transactions.prefix(2).map(\.id))

        let updated = try XCTUnwrap(store.updateSingleAccountTransactions(
            ids: selected, accountID: data.accounts[1].id
        ))

        XCTAssertEqual(updated, eligible)
        XCTAssertEqual(selected.subtracting(updated).count, 3)
        XCTAssertEqual(store.data.transactions[0].outflows[0].accountID, data.accounts[1].id)
        XCTAssertEqual(store.data.transactions[1].inflows[0].accountID, data.accounts[1].id)
        XCTAssertEqual(Array(store.data.transactions.suffix(2)), Array(data.transactions.suffix(2)))
    }

    @MainActor
    func testBulkAccountChangeReportsCompleteSuccessAndNoEligibleEntries() throws {
        let data = makeLedger()
        let (store, _) = try makeStore(with: data)
        let eligible = Set(data.transactions.prefix(2).map(\.id))
        XCTAssertEqual(store.updateSingleAccountTransactions(ids: eligible, accountID: data.accounts[1].id), eligible)

        let saved = store.data
        let ineligible = Set(data.transactions.suffix(2).map(\.id))
        XCTAssertNil(store.updateSingleAccountTransactions(ids: ineligible, accountID: data.accounts[1].id))
        XCTAssertEqual(store.data, saved)
        XCTAssertEqual(store.lastActionStatus, "No selected single-account transactions matched that account")
    }

    @MainActor
    func testBulkAccountPersistenceConflictDoesNotReportSuccess() throws {
        let data = makeLedger()
        let (store, databaseURL) = try makeStore(with: data)
        var concurrentData = data
        concurrentData.transactions[0].note = "Changed in another surface"
        XCTAssertTrue(FinanceStorage(databaseURL: databaseURL).save(concurrentData))

        XCTAssertNil(store.updateSingleAccountTransactions(
            ids: [data.transactions[0].id], accountID: data.accounts[1].id
        ))
        XCTAssertEqual(store.data, concurrentData)
        XCTAssertTrue(store.lastActionStatus?.contains("was not saved") == true)
    }

    @MainActor
    func testBulkCategoryChangeReportsSkippedLoanActivity() throws {
        var data = makeLedger()
        let loan = Loan(counterparty: "Test loan", direction: .lent, currency: .usd,
                        startingAmount: Money(currency: .usd, minorUnits: 100))
        let funding = LedgerTransaction(
            note: "Loan funding", kind: .expense, categoryID: nil,
            outflows: [MoneyMovement(accountID: data.accounts[0].id, money: loan.startingAmount)],
            inflows: [], loanID: loan.id
        )
        data.loans = [loan]
        data.transactions.append(funding)
        let (store, _) = try makeStore(with: data)
        let selected: Set<UUID> = [data.transactions[0].id, funding.id]

        XCTAssertEqual(store.updateTransactionCategories(ids: selected, categoryID: data.categories[0].id),
                       [data.transactions[0].id])
        XCTAssertEqual(store.data.transactions[0].categoryID, data.categories[0].id)
        XCTAssertEqual(store.data.transactions.last, funding)
        XCTAssertNil(store.updateTransactionCategories(ids: [funding.id], categoryID: data.categories[0].id))
    }

    func testFilterSummaryIncludesTypeRangeAndIndependentCondition() {
        XCTAssertEqual(TransactionListSnapshot.filterSummary(
            filter: .income, quickFilter: .needsReceipt, periodTitle: "All time"
        ), "Income · All time · Needs receipt")
        XCTAssertEqual(TransactionListSnapshot.filterSummary(
            filter: .expense, quickFilter: .cash, periodTitle: "Jan 1–Jan 31"
        ), "Expenses · Jan 1–Jan 31 · Cash")
        XCTAssertEqual(TransactionListSnapshot.filterSummary(
            filter: .all, quickFilter: .none, periodTitle: "All time"
        ), "All · All time")
    }

    func testManualFiltersInvalidateOnlyIncompatiblePresets() {
        XCTAssertEqual(TransactionQuickFilter.uncategorized.reconciled(with: .all, period: .all), .none)
        XCTAssertEqual(TransactionQuickFilter.uncategorized.reconciled(with: .uncategorized, period: .thisMonth), .uncategorized)
        XCTAssertEqual(TransactionQuickFilter.thisMonth.reconciled(with: .all, period: .all), .none)
        XCTAssertEqual(TransactionQuickFilter.thisMonth.reconciled(with: .income, period: .thisMonth), .none)
        XCTAssertEqual(TransactionQuickFilter.thisMonth.reconciled(with: .all, period: .thisMonth), .thisMonth)
        XCTAssertEqual(TransactionQuickFilter.cash.reconciled(with: .income, period: .thisMonth), .cash)
        XCTAssertEqual(TransactionQuickFilter.needsReceipt.reconciled(with: .income, period: .all), .needsReceipt)
    }

    func testImportDiscardProtectionCoversEditsAndReturningToSource() {
        let table = ImportedTable(id: "transactions", name: "Transactions", columns: ["Amount"], rows: [["10"]])
        let document = ImportedDocument(fileName: "ledger.csv", format: .delimited, tables: [table])
        var draft = ImportDraft(document: document, existing: .empty, rememberedRules: ImportStoredRules())
        let initial = ImportPreparationInputs(draft: draft, ledgerRevision: 4)
        XCTAssertFalse(initial.requiresDiscardConfirmation(for: draft, hasAdvancedPastSource: false))

        draft.defaultCurrency = .lbp
        XCTAssertTrue(initial.requiresDiscardConfirmation(for: draft, hasAdvancedPastSource: false))
        draft.defaultCurrency = initial.defaultCurrency
        draft.mapping[.amount] = "Changed column"
        XCTAssertTrue(initial.requiresDiscardConfirmation(for: draft, hasAdvancedPastSource: false))

        draft.mapping = initial.mapping
        draft.step = .source
        XCTAssertFalse(initial.requiresDiscardConfirmation(for: draft, hasAdvancedPastSource: false))
        XCTAssertTrue(initial.requiresDiscardConfirmation(for: draft, hasAdvancedPastSource: true))
    }

    @MainActor
    private func makeStore(with data: FinanceData) throws -> (LedgerStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("ledger.sqlite")
        let storage = FinanceStorage(databaseURL: databaseURL)
        guard storage.save(data) else { throw CocoaError(.fileWriteUnknown) }
        return (LedgerStore(storage: storage), databaseURL)
    }

    private func makeLedger() -> FinanceData {
        let source = Account(name: "Source", type: .cash, currency: .usd,
                             openingBalance: Money(currency: .usd, minorUnits: 10_000))
        let target = Account(name: "Target", type: .cash, currency: .usd,
                             openingBalance: Money(currency: .usd, minorUnits: 10_000))
        let foreign = Account(name: "LBP", type: .cash, currency: .lbp,
                              openingBalance: Money(currency: .lbp, minorUnits: 10_000))
        var data = FinanceData.empty
        data.accounts = [source, target, foreign]
        data.categories = [LedgerCategory(name: "Food")]
        data.transactions = [
            LedgerTransaction(note: "Expense", kind: .expense, categoryID: nil,
                              outflows: [MoneyMovement(accountID: source.id, money: Money(currency: .usd, minorUnits: 100))], inflows: []),
            LedgerTransaction(note: "Income", kind: .income, categoryID: nil, outflows: [],
                              inflows: [MoneyMovement(accountID: source.id, money: Money(currency: .usd, minorUnits: 200))]),
            LedgerTransaction(note: "Split", kind: .expense, categoryID: nil,
                              outflows: [MoneyMovement(accountID: source.id, money: Money(currency: .usd, minorUnits: 50)),
                                         MoneyMovement(accountID: target.id, money: Money(currency: .usd, minorUnits: 50))], inflows: []),
            LedgerTransaction(note: "LBP", kind: .expense, categoryID: nil,
                              outflows: [MoneyMovement(accountID: foreign.id, money: Money(currency: .lbp, minorUnits: 1_000))], inflows: [])
        ]
        return data
    }
}
