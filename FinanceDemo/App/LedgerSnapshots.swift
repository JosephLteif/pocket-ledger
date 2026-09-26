import Foundation

struct MetricsCategorySnapshot: Identifiable {
    let id: String
    let categoryID: UUID?
    let title: String
    let currency: LedgerCurrency
    let amount: Int64
    let count: Int
    let colorIndex: Int
}

struct MetricsAccountSnapshot: Identifiable {
	let id: String
    let accountID: UUID
    let title: String
    let currency: LedgerCurrency
    let amount: Int64
    let count: Int
    let colorIndex: Int
}

struct MetricsSnapshot {
    let filteredTransactions: [LedgerTransaction]
    let income: Int64
    let expenses: Int64
    let activityCounts: [TransactionKind: Int]
    let categories: [MetricsCategorySnapshot]
    let accounts: [MetricsAccountSnapshot]

    static var empty: MetricsSnapshot {
        MetricsSnapshot(
            filteredTransactions: [],
            income: 0,
            expenses: 0,
            activityCounts: [:],
            categories: [],
            accounts: []
        )
    }

    static func make(
        index: LedgerIndex,
        interval: DateInterval,
        selectedCurrency: LedgerCurrency,
        selectedCategoryID: UUID?
    ) -> MetricsSnapshot {
        var filteredTransactions: [LedgerTransaction] = []
        var income: Int64 = 0
        var expenses: Int64 = 0
        var activityCounts: [TransactionKind: Int] = [:]
        var categoryTotals: [UUID?: (title: String, amount: Int64, count: Int)] = [:]
        var accountTotals: [UUID: (amount: Int64, transactionCount: Int)] = [:]

        for transaction in index.sortedTransactions {
            guard interval.contains(transaction.date),
                  index.categoryMatches(
                      transaction.categoryID,
                      selectedCategoryID: selectedCategoryID
                  ),
                  index.categoryIncludedInTotals(transaction.categoryID),
                  index.transactionHasIncludedAccount(transaction) else {
                continue
            }

            filteredTransactions.append(transaction)
            activityCounts[transaction.kind, default: 0] += 1

            switch transaction.kind {
            case .income:
                income += index.movementTotal(
                    transaction.inflows,
                    currency: selectedCurrency,
                    exchangeRate: transaction.exchangeRate
                )
            case .expense:
                let amount = index.netExpenseAmount(transaction, currency: selectedCurrency)
                expenses += amount
                guard amount > 0 else { continue }
                let groupID = index.topLevelCategoryID(for: transaction.categoryID)
                let current = categoryTotals[groupID]
                    ?? (index.categoryName(for: groupID), 0, 0)
                categoryTotals[groupID] = (
                    current.title,
                    current.amount + amount,
                    current.count + 1
                )

                var accountNetAmounts: [UUID: Int64] = [:]
                for movement in transaction.outflows {
                    guard index.includesInTotals(accountID: movement.accountID),
                          let converted = financeConvertedMinorUnits(
                              movement.money,
                              to: selectedCurrency,
                              using: transaction.exchangeRate
                          ) else {
                        continue
                    }
                    accountNetAmounts[movement.accountID, default: 0] += converted
                }
                for movement in transaction.inflows {
                    guard index.includesInTotals(accountID: movement.accountID),
                          let converted = financeConvertedMinorUnits(
                              movement.money,
                              to: selectedCurrency,
                              using: transaction.exchangeRate
                          ) else {
                        continue
                    }
                    accountNetAmounts[movement.accountID, default: 0] -= converted
                }

                for (accountID, amount) in accountNetAmounts where amount > 0 {
                    guard index.account(with: accountID) != nil else { continue }
                    let current = accountTotals[accountID]
                        ?? (amount: 0, transactionCount: 0)
                    accountTotals[accountID] = (
                        current.amount + amount,
                        current.transactionCount + 1
                    )
                }
            case .transfer:
                break
            }
        }

        let categories = categoryTotals
            .map { categoryID, value in
                (
                    categoryID: categoryID,
                    title: value.title,
                    amount: value.amount,
                    count: value.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return (lhs.categoryID?.uuidString ?? "") < (rhs.categoryID?.uuidString ?? "")
            }
            .enumerated()
            .map { index, value in
                MetricsCategorySnapshot(
                    id: "\(value.categoryID?.uuidString ?? "uncategorized")-\(selectedCurrency.rawValue)",
                    categoryID: value.categoryID,
                    title: value.title,
                    currency: selectedCurrency,
                    amount: value.amount,
                    count: value.count,
                    colorIndex: index
                )
            }

        let accounts = accountTotals
            .compactMap { accountID, value -> (accountID: UUID, title: String, amount: Int64, count: Int)? in
                guard let account = index.account(with: accountID) else { return nil }
                return (
                    accountID: accountID,
                    title: account.name,
                    amount: value.amount,
                    count: value.transactionCount
                )
            }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.accountID.uuidString < rhs.accountID.uuidString
            }
            .enumerated()
            .map { index, value in
                MetricsAccountSnapshot(
                    id: "\(value.accountID.uuidString)-\(selectedCurrency.rawValue)",
                    accountID: value.accountID,
                    title: value.title,
                    currency: selectedCurrency,
                    amount: value.amount,
                    count: value.count,
                    colorIndex: index
                )
            }

        return MetricsSnapshot(
            filteredTransactions: filteredTransactions,
            income: income,
            expenses: expenses,
            activityCounts: activityCounts,
            categories: categories,
            accounts: accounts
        )
    }

    static func subcategoryBreakdown(
        index: LedgerIndex,
        categoryID: UUID?,
        interval: DateInterval,
        selectedCurrency: LedgerCurrency
    ) -> [MetricsCategorySnapshot] {
        guard let categoryID else { return [] }

        var totals: [UUID: (title: String, amount: Int64, count: Int)] = [:]
        for transaction in index.sortedTransactions {
            guard transaction.kind == .expense,
                  interval.contains(transaction.date),
                  index.categoryMatches(
                      transaction.categoryID,
                      selectedCategoryID: categoryID
                  ),
                  index.categoryIncludedInTotals(transaction.categoryID),
                  index.transactionHasIncludedAccount(transaction),
                  let subcategoryID = index.directDescendantCategoryID(
                      for: transaction.categoryID,
                      under: categoryID
                  ) else {
                continue
            }

            let amount = index.netExpenseAmount(transaction, currency: selectedCurrency)
            guard amount > 0 else { continue }

            let current = totals[subcategoryID]
                ?? (index.categoryName(for: subcategoryID), 0, 0)
            totals[subcategoryID] = (
                current.title,
                current.amount + amount,
                current.count + 1
            )
        }

        return totals
            .map { categoryID, value in
                (categoryID: categoryID, title: value.title, amount: value.amount, count: value.count)
            }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.categoryID.uuidString < rhs.categoryID.uuidString
            }
            .enumerated()
            .map { index, value in
                MetricsCategorySnapshot(
                    id: "detail-\(value.categoryID.uuidString)-\(selectedCurrency.rawValue)",
                    categoryID: value.categoryID,
                    title: value.title,
                    currency: selectedCurrency,
                    amount: value.amount,
                    count: value.count,
                    colorIndex: index
                )
            }
    }
}

struct DashboardBudgetSnapshot: Identifiable {
    let budget: LedgerBudget
    let categoryPath: String
    let spent: Money
    let allowance: Money
    let projected: Money
    let remaining: Int64
    let ratio: Double
    let isOver: Bool
    let isProjectedOver: Bool
    let percentUsed: Int
    let daysLeft: Int

    var id: UUID { budget.id }
}

struct DashboardSnapshot {
    let attentionItems: [FinanceAttentionItem]
    let availableBalances: [LedgerCurrency: Money]
    let activeAccounts: [Account]
    let includedAccountCount: Int
    let excludedAccountCount: Int
    let monthExpenses: [LedgerCurrency: Int64]
    let monthTransactionCount: Int
    let topCategory: String?
    let recentTransactions: [LedgerTransaction]
    let upcomingSchedules: [ScheduledTransaction]
    let cashFlowSchedules: [ScheduledTransaction]
    let scheduledChanges: [LedgerCurrency: Int64]
    let budgetSummaries: [DashboardBudgetSnapshot]

    static var empty: DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: [],
            availableBalances: [:],
            activeAccounts: [],
            includedAccountCount: 0,
            excludedAccountCount: 0,
            monthExpenses: [:],
            monthTransactionCount: 0,
            topCategory: nil,
            recentTransactions: [],
            upcomingSchedules: [],
            cashFlowSchedules: [],
            scheduledChanges: [:],
            budgetSummaries: []
        )
    }

    static func make(
        data: FinanceData,
        index: LedgerIndex,
        attentionItems: [FinanceAttentionItem],
        date: Date = .now,
        calendar: Calendar = .current
    ) -> DashboardSnapshot {
        let activeAccounts = index.activeAccounts
        let includedAccountCount = activeAccounts.filter(\.includeInTotals).count
        let upcomingSchedules = data.scheduledTransactions
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                if lhs.nextRunDate != rhs.nextRunDate {
                    return lhs.nextRunDate < rhs.nextRunDate
                }
                return lhs.note.localizedCaseInsensitiveCompare(rhs.note) == .orderedAscending
            }
        let horizon = calendar.date(byAdding: .day, value: 30, to: date) ?? date
        let cashFlowSchedules = upcomingSchedules.filter { $0.nextRunDate <= horizon }

        var scheduledChanges: [LedgerCurrency: Int64] = [:]
        for schedule in cashFlowSchedules {
            for movement in schedule.inflows {
                guard index.includesInTotals(accountID: movement.accountID) else { continue }
                scheduledChanges[movement.money.currency, default: 0] += movement.money.minorUnits
            }
            for movement in schedule.outflows {
                guard index.includesInTotals(accountID: movement.accountID) else { continue }
                scheduledChanges[movement.money.currency, default: 0] -= movement.money.minorUnits
            }
        }

        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? .distantPast
        var categoryCounts: [UUID: Int] = [:]
        var monthTransactionCount = 0
        for transaction in index.sortedTransactions where transaction.date >= monthStart {
            if index.transactionHasIncludedAccount(transaction) {
                monthTransactionCount += 1
            }
            guard transaction.kind == .expense,
                  index.categoryIncludedInTotals(transaction.categoryID),
                  transaction.outflows.contains(where: {
                      index.includesInTotals(accountID: $0.accountID)
                  }),
                  let categoryID = transaction.categoryID else {
                continue
            }
            categoryCounts[categoryID, default: 0] += 1
        }

        return DashboardSnapshot(
            attentionItems: attentionItems,
            availableBalances: LedgerCurrency.allCases.reduce(into: [LedgerCurrency: Money]()) { result, currency in
                result[currency] = index.availableBalance(for: currency)
            },
            activeAccounts: activeAccounts,
            includedAccountCount: includedAccountCount,
            excludedAccountCount: activeAccounts.count - includedAccountCount,
            monthExpenses: index.monthlyExpenseTotals(for: date, calendar: calendar),
            monthTransactionCount: monthTransactionCount,
            topCategory: categoryCounts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return (index.categoryPath(for: lhs.key)) > (index.categoryPath(for: rhs.key))
            }.map { index.categoryPath(for: $0.key) },
            recentTransactions: index.sortedTransactions,
            upcomingSchedules: upcomingSchedules,
            cashFlowSchedules: cashFlowSchedules,
            scheduledChanges: scheduledChanges,
            budgetSummaries: makeBudgetSummaries(
                data: data,
                index: index,
                date: date,
                calendar: calendar
            )
        )
    }

    static func makeBudgetSummaries(
        data: FinanceData,
        index: LedgerIndex,
        date: Date = .now,
        calendar: Calendar = .current
    ) -> [DashboardBudgetSnapshot] {
        data.budgets.map { budget in
            let monthInterval = calendar.dateInterval(of: .month, for: date)
                ?? DateInterval(start: date, duration: 0)
            let spent = index.budgetSpent(
                budget,
                interval: monthInterval,
                calendar: calendar
            )
            let allowance = financeBudgetAllowance(
                budget,
                in: data,
                interval: monthInterval,
                using: index,
                calendar: calendar
            )
            let calendarDayCount = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
            let elapsedDay = calendar.component(.day, from: date)
            let progressThroughMonth = min(
                max(Double(elapsedDay) / Double(max(calendarDayCount, 1)), 0.01),
                1
            )
            let projected = Int64(
                (Double(spent.minorUnits) / progressThroughMonth).rounded()
            )
            let remaining = allowance.minorUnits - spent.minorUnits
            return DashboardBudgetSnapshot(
                budget: budget,
                categoryPath: index.categoryPath(for: budget.categoryID),
                spent: spent,
                allowance: allowance,
                projected: Money(currency: budget.currency, minorUnits: projected),
                remaining: remaining,
                ratio: min(
                    Double(spent.minorUnits) / Double(max(allowance.minorUnits, 1)),
                    1
                ),
                isOver: spent.minorUnits > allowance.minorUnits,
                isProjectedOver: projected > allowance.minorUnits,
                percentUsed: Int(
                    (Double(spent.minorUnits) / Double(max(allowance.minorUnits, 1)) * 100).rounded()
                ),
                daysLeft: max(calendarDayCount - elapsedDay, 0)
            )
        }
    }
}
