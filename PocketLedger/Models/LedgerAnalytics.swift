import Foundation

struct LedgerIndex {
    struct MonthCategoryCurrencyKey: Hashable {
        let monthStart: Date
        let categoryID: UUID?
        let currency: LedgerCurrency
    }

    let accountsByID: [UUID: Account]
    let loansByID: [UUID: Loan]
    let categoriesByID: [UUID: LedgerCategory]
    let includedAccountIDs: Set<UUID>
    let activeAccounts: [Account]
    let loans: [Loan]
    let activeCategories: [LedgerCategory]
    let rootCategories: [LedgerCategory]
    let categoryPathsByID: [UUID: String]
    let categoryAncestorsByID: [UUID: [UUID]]
    let sortedTransactions: [LedgerTransaction]
    let balancesByAccountID: [UUID: Int64]
    let valuationData: FinanceData
    let expenseTotalsByMonthCategoryCurrency: [MonthCategoryCurrencyKey: Int64]

    init(data: FinanceData, calendar: Calendar = .current) {
        self.valuationData = data
        let accountsByID = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        let loansByID = Dictionary(uniqueKeysWithValues: data.loans.map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: data.categories.map { ($0.id, $0) })
        let includedAccountIDs = Set(
            data.accounts.filter(\.includeInTotals).map(\.id)
        )

        self.accountsByID = accountsByID
        self.loansByID = loansByID
        self.categoriesByID = categoriesByID
        self.includedAccountIDs = includedAccountIDs
        self.activeAccounts = data.accounts.filter { !$0.isArchived }
        self.loans = data.loans
        self.activeCategories = data.categories.filter { !$0.isArchived }
        self.rootCategories = data.categories.filter { $0.parentID == nil && !$0.isArchived }

        var categoryAncestorsByID: [UUID: [UUID]] = [:]
        var categoryPathsByID: [UUID: String] = [:]
        for category in data.categories {
            var ancestors: [UUID] = []
            var visited: Set<UUID> = []
            var currentID: UUID? = category.id

            while let id = currentID,
                  visited.insert(id).inserted,
                  let current = categoriesByID[id] {
                ancestors.append(id)
                currentID = current.parentID
            }

            categoryAncestorsByID[category.id] = ancestors
            let names = ancestors.reversed().compactMap { categoriesByID[$0]?.name }
            categoryPathsByID[category.id] = names.isEmpty
                ? "Uncategorized"
                : names.joined(separator: " / ")
        }
        self.categoryAncestorsByID = categoryAncestorsByID
        self.categoryPathsByID = categoryPathsByID

        self.sortedTransactions = data.transactions.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var balancesByAccountID = data.accounts.reduce(into: [UUID: Int64]()) {
            $0[$1.id] = $1.openingBalance.minorUnits
        }
        for transaction in data.transactions {
            for movement in transaction.outflows {
                guard let account = accountsByID[movement.accountID],
                      let amount = financeConvertedMinorUnits(
                          movement.money,
                          to: account.currency,
                          using: transaction.exchangeRate
                      ) else {
                    continue
                }
                balancesByAccountID[movement.accountID, default: 0] -= amount
            }
            for movement in transaction.inflows {
                guard let account = accountsByID[movement.accountID],
                      let amount = financeConvertedMinorUnits(
                          movement.money,
                          to: account.currency,
                          using: transaction.exchangeRate
                      ) else {
                    continue
                }
                balancesByAccountID[movement.accountID, default: 0] += amount
            }
        }
        self.balancesByAccountID = balancesByAccountID

        self.expenseTotalsByMonthCategoryCurrency = Self.makeExpenseTotals(
            transactions: data.transactions,
            accountsByID: accountsByID,
            categoriesByID: categoriesByID,
            categoryAncestorsByID: categoryAncestorsByID,
            calendar: calendar
        )
    }

    func account(with id: UUID) -> Account? {
        accountsByID[id]
    }

    func loan(with id: UUID) -> Loan? {
        loansByID[id]
    }

    func includesInTotals(accountID: UUID) -> Bool {
        accountsByID[accountID] == nil || includedAccountIDs.contains(accountID)
    }

    func transactionHasIncludedAccount(_ transaction: LedgerTransaction) -> Bool {
        let movements: [MoneyMovement]
        switch transaction.kind {
        case .expense:
            movements = transaction.outflows
        case .income:
            movements = transaction.inflows
        case .transfer:
            movements = transaction.outflows + transaction.inflows
        }
        return movements.contains { includesInTotals(accountID: $0.accountID) }
    }

    func categoryIncludedInTotals(_ categoryID: UUID?) -> Bool {
        guard let categoryID else { return true }

        let ancestorIDs = categoryAncestorsByID[categoryID] ?? [categoryID]
        for id in ancestorIDs {
            guard let category = categoriesByID[id] else { break }
            let categoryName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if category.parentID == nil,
               categoryName.caseInsensitiveCompare("Modified Bal.") == .orderedSame {
                return false
            }
            if !category.includeInTotals {
                return false
            }
        }
        return true
    }

    func categoryIncludedInTotals(_ transaction: LedgerTransaction) -> Bool {
        transaction.effectiveCategoryIDs.contains { categoryIncludedInTotals($0) }
    }

    func categoryMatches(_ categoryID: UUID?, selectedCategoryID: UUID?) -> Bool {
        guard let selectedCategoryID else { return true }
        guard let categoryID else { return false }
        return categoryAncestorsByID[categoryID]?.contains(selectedCategoryID) ?? (categoryID == selectedCategoryID)
    }

    func categoryMatches(_ transaction: LedgerTransaction, selectedCategoryID: UUID?) -> Bool {
        guard let selectedCategoryID else { return true }
        return transaction.effectiveCategoryIDs.contains {
            categoryMatches($0, selectedCategoryID: selectedCategoryID)
        }
    }

    func hasUncategorizedAllocation(_ transaction: LedgerTransaction) -> Bool {
        transaction.effectiveCategoryIDs.contains(nil)
    }

    func categorySummary(for transaction: LedgerTransaction) -> String {
        let paths = Array(Set(transaction.effectiveCategoryIDs.map { categoryPath(for: $0) })).sorted()
        return paths.joined(separator: " · ")
    }

    func categoryAllocationAmounts(
        for transaction: LedgerTransaction,
        currency: LedgerCurrency
    ) -> [TransactionCategoryAllocation] {
        financeCategoryAllocationAmounts(
            transaction,
            currency: currency,
            accountsByID: accountsByID
        )
    }

    func categoryPath(for categoryID: UUID?) -> String {
        guard let categoryID else { return "Uncategorized" }
        return categoryPathsByID[categoryID] ?? "Uncategorized"
    }

    func categoryName(for categoryID: UUID?) -> String {
        guard let categoryID else { return "Uncategorized" }
        return categoriesByID[categoryID]?.name ?? "Uncategorized"
    }

    func topLevelCategoryID(for categoryID: UUID?) -> UUID? {
        guard let categoryID else { return nil }
        return categoryAncestorsByID[categoryID]?.last
    }

    func directDescendantCategoryID(
        for categoryID: UUID?,
        under ancestorID: UUID
    ) -> UUID? {
        guard let categoryID,
              let ancestors = categoryAncestorsByID[categoryID],
              let ancestorIndex = ancestors.firstIndex(of: ancestorID),
              ancestorIndex > 0 else {
            return nil
        }
        return ancestors[ancestorIndex - 1]
    }

    func categorySystemImage(for categoryID: UUID?) -> String {
        guard let categoryID else { return "tag.fill" }
        return categoriesByID[categoryID]?.systemImage ?? "tag.fill"
    }

    func balance(for account: Account) -> Money {
        Money(
            currency: account.currency,
            minorUnits: balancesByAccountID[account.id] ?? account.openingBalance.minorUnits
        )
    }

    func valuation(for account: Account) -> Money {
        FinanceAssetTracking.valuation(account: account, recordedBalance: balance(for: account), data: valuationData)
    }

    func assetValuationBalance(for currency: LedgerCurrency) -> Money {
        Money(currency: currency, minorUnits: activeAccounts
            .filter { $0.currency == currency && $0.type != .loan && $0.includeInTotals }
            .reduce(Int64.zero) { $0 + valuation(for: $1).minorUnits })
    }

    func availableBalance(for currency: LedgerCurrency) -> Money {
        assetValuationBalance(for: currency)
    }

    func loanBalance(for currency: LedgerCurrency) -> Money {
        let total = activeAccounts
            .filter { $0.currency == currency && $0.type == .loan && $0.includeInTotals }
            .reduce(Int64.zero) { $0 + (balancesByAccountID[$1.id] ?? $1.openingBalance.minorUnits) }
        return Money(currency: currency, minorUnits: total)
    }

    func lentLoanBalance(for currency: LedgerCurrency) -> Money {
        let total = loans
            .filter { $0.currency == currency && $0.direction == .lent }
            .reduce(Int64.zero) { $0 + $1.outstandingAmount.minorUnits }
        return Money(currency: currency, minorUnits: total)
    }

    func borrowedLoanBalance(for currency: LedgerCurrency) -> Money {
        let total = loans
            .filter { $0.currency == currency && $0.direction == .borrowed }
            .reduce(Int64.zero) { $0 + $1.outstandingAmount.minorUnits }
        return Money(currency: currency, minorUnits: total)
    }

    func movementTotal(
        _ movements: [MoneyMovement],
        currency: LedgerCurrency,
        exchangeRate: ExchangeRate?
    ) -> Int64 {
        Self.movementTotal(
            movements,
            currency: currency,
            exchangeRate: exchangeRate,
            accountsByID: accountsByID
        )
    }

    private static func movementTotal(
        _ movements: [MoneyMovement],
        currency: LedgerCurrency,
        exchangeRate: ExchangeRate?,
        accountsByID: [UUID: Account]
    ) -> Int64 {
        movements.reduce(Int64.zero) { total, movement in
            guard accountsByID[movement.accountID]?.includeInTotals == true,
                  let converted = financeConvertedMinorUnits(
                      movement.money,
                      to: currency,
                      using: exchangeRate
                  ) else {
                return total
            }
            return total + converted
        }
    }

    func netExpenseAmount(_ transaction: LedgerTransaction, currency: LedgerCurrency) -> Int64 {
        guard transaction.kind == .expense else {
            return 0
        }
        return categoryAllocationAmounts(for: transaction, currency: currency)
            .filter { categoryIncludedInTotals($0.categoryID) }
            .reduce(Int64.zero) { $0 + $1.amount.minorUnits }
    }

    func monthlyExpenseTotals(
        for date: Date,
        calendar: Calendar = .current
    ) -> [LedgerCurrency: Int64] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [:] }
        return LedgerCurrency.allCases.reduce(into: [LedgerCurrency: Int64]()) { result, currency in
            let total = dataForMonth(
                interval.start,
                categoryID: nil,
                currency: currency,
                calendar: calendar
            )
            result[currency] = total
        }
    }

    func budgetSpent(
        _ budget: LedgerBudget,
        interval: DateInterval,
        calendar: Calendar = .current
    ) -> Money {
        guard let month = calendar.dateInterval(of: .month, for: interval.start),
              month.start == interval.start,
              month.end == interval.end else {
            let total = sortedTransactions
                .filter {
                    $0.kind == .expense
                        && interval.contains($0.date)
                }
                .reduce(Int64.zero) { total, transaction in
                    total + categoryAllocationAmounts(for: transaction, currency: budget.currency)
                        .filter {
                            $0.categoryID == budget.categoryID
                                && categoryIncludedInTotals($0.categoryID)
                        }
                        .reduce(Int64.zero) { $0 + $1.amount.minorUnits }
                }
            return Money(currency: budget.currency, minorUnits: total)
        }

        return Money(
            currency: budget.currency,
            minorUnits: dataForMonth(
                month.start,
                categoryID: budget.categoryID,
                currency: budget.currency,
                calendar: calendar
            )
        )
    }

    func dataForMonth(
        _ monthStart: Date,
        categoryID: UUID?,
        currency: LedgerCurrency,
        calendar: Calendar = .current
    ) -> Int64 {
        let key = MonthCategoryCurrencyKey(
            monthStart: calendar.dateInterval(of: .month, for: monthStart)?.start ?? monthStart,
            categoryID: categoryID,
            currency: currency
        )
        if categoryID != nil {
            return expenseTotalsByMonthCategoryCurrency[key] ?? 0
        }

        return expenseTotalsByMonthCategoryCurrency
            .filter { $0.key.monthStart == key.monthStart && $0.key.currency == currency }
            .reduce(Int64.zero) { $0 + $1.value }
    }

    private static func makeExpenseTotals(
        transactions: [LedgerTransaction],
        accountsByID: [UUID: Account],
        categoriesByID: [UUID: LedgerCategory],
        categoryAncestorsByID: [UUID: [UUID]],
        calendar: Calendar
    ) -> [MonthCategoryCurrencyKey: Int64] {
        func categoryIncludedInTotals(_ categoryID: UUID?) -> Bool {
            guard let categoryID else { return true }
            for id in categoryAncestorsByID[categoryID] ?? [categoryID] {
                guard let category = categoriesByID[id] else { break }
                let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if category.parentID == nil,
                   name.caseInsensitiveCompare("Modified Bal.") == .orderedSame {
                    return false
                }
                if !category.includeInTotals { return false }
            }
            return true
        }

        var totals: [MonthCategoryCurrencyKey: Int64] = [:]
        for transaction in transactions where transaction.kind == .expense {
            guard let monthStart = calendar.dateInterval(of: .month, for: transaction.date)?.start else {
                continue
            }

            for currency in LedgerCurrency.allCases {
                let allocations = financeCategoryAllocationAmounts(
                    transaction,
                    currency: currency,
                    accountsByID: accountsByID
                )
                for allocation in allocations where allocation.amount.minorUnits > 0 {
                    guard categoryIncludedInTotals(allocation.categoryID) else { continue }
                    let key = MonthCategoryCurrencyKey(
                        monthStart: monthStart,
                        categoryID: allocation.categoryID,
                        currency: currency
                    )
                    totals[key, default: 0] += allocation.amount.minorUnits
                }
            }
        }
        return totals
    }
}

func financeBudgetSpent(
    _ budget: LedgerBudget,
    in _: FinanceData,
    interval: DateInterval? = nil,
    using index: LedgerIndex
) -> Money {
    let period = interval ?? (
        Calendar.current.dateInterval(of: .month, for: .now)
            ?? DateInterval(start: .distantPast, duration: .zero)
    )
    return index.budgetSpent(budget, interval: period)
}

func financeBudgetAllowance(
    _ budget: LedgerBudget,
    in _: FinanceData,
    interval: DateInterval? = nil,
    using index: LedgerIndex,
    calendar: Calendar = .current
) -> Money {
    let currentMonth = interval ?? (
        Calendar.current.dateInterval(of: .month, for: .now)
            ?? DateInterval(start: .distantPast, duration: .zero)
    )
    guard budget.rollover else { return budget.monthlyLimit }

    let startingMonth = calendar.dateInterval(
        of: .month,
        for: budget.startedAt ?? currentMonth.start
    )?.start ?? currentMonth.start
    var month = startingMonth
    var carry = Int64.zero

    while month < currentMonth.start {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { break }
        let spent = index.budgetSpent(
            budget,
            interval: monthInterval,
            calendar: calendar
        ).minorUnits
        carry = max(carry + budget.monthlyLimit.minorUnits - spent, 0)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: month),
              nextMonth > month else {
            break
        }
        month = nextMonth
    }

    return Money(
        currency: budget.currency,
        minorUnits: budget.monthlyLimit.minorUnits + carry
    )
}
