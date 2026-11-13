import XCTest
@testable import PocketLedger

final class SplitCategoryListTests: XCTestCase {
    func testCategoryFilterAndSearchFindSplitPayments() {
        let account = Account(name: "Cash", type: .cash, currency: .usd,
                              openingBalance: Money(currency: .usd, minorUnits: 10_000))
        let food = LedgerCategory(name: "Food")
        let travel = LedgerCategory(name: "Travel")
        let transaction = LedgerTransaction(note: "Split purchase", kind: .expense, categoryID: food.id, outflows: [
            MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 600)),
            MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 400), categoryID: travel.id)
        ], inflows: [])
        let index = LedgerIndex(data: FinanceData(accounts: [account], categories: [food, travel],
                                                 transactions: [transaction]))
        let snapshot = TransactionListSnapshot.make(
            index: index, filter: .expense, period: .all, quickFilter: .none, searchText: "Travel",
            customStartDate: .now, customEndDate: .now, page: 0, pageSize: 50,
            categoryID: travel.id, reportingCurrency: .usd
        )
        XCTAssertEqual(snapshot.filteredTransactions.map(\.id), [transaction.id])
        XCTAssertEqual(snapshot.expenseTotals[.usd], 400)
    }
}
