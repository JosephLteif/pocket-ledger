import Foundation

struct MetricsCategorySnapshot: Identifiable {
    let id: String
    let categoryID: UUID?
    let title: String
    let currency: LedgerCurrency
    let amount: Int64
    let count: Int
}

struct MetricsAccountSnapshot: Identifiable {
	let id: String
    let accountID: UUID
    let title: String
    let currency: LedgerCurrency
    let amount: Int64
    let count: Int
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
            let matchesCategory = transaction.kind == .expense
                ? index.transactionMatchesCategory(
                    transaction,
                    selectedCategoryID: selectedCategoryID
                )
                : index.categoryMatches(
                    transaction.categoryID,
                    selectedCategoryID: selectedCategoryID
                )
            let categoryIncluded = transaction.kind == .expense
                ? index.transactionCategoryIncludedInTotals(
                    transaction,
                    selectedCategoryID: selectedCategoryID
                )
                : index.categoryIncludedInTotals(transaction.categoryID)
            let hasIncludedAccount = transaction.kind == .expense
                || index.transactionHasIncludedAccount(transaction)
            guard interval.contains(transaction.date),
                  matchesCategory,
                  categoryIncluded,
                  hasIncludedAccount else {
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
                let categoryAmounts = index.expenseAmountsByCategory(transaction, currency: selectedCurrency)
                    .filter { index.categoryMatches($0.key, selectedCategoryID: selectedCategoryID) }
                let amount = max(categoryAmounts.reduce(0) { $0 + $1.value }, 0)
                expenses += amount
                var amountsByTopLevelCategory: [UUID?: Int64] = [:]
                for (categoryID, categoryAmount) in categoryAmounts {
                    let groupID = index.topLevelCategoryID(for: categoryID)
                    amountsByTopLevelCategory[groupID, default: 0] += categoryAmount
                }
                for (groupID, categoryAmount) in amountsByTopLevelCategory where categoryAmount != 0 {
                    let current = categoryTotals[groupID]
                        ?? (index.categoryName(for: groupID), 0, 0)
                    categoryTotals[groupID] = (
                        current.title,
                        current.amount + categoryAmount,
                        current.count + 1
                    )
                }

                var accountNetAmounts: [UUID: Int64] = [:]
                for movement in transaction.outflows {
                    guard index.categoryMatches(
                            transaction.categoryID(for: movement),
                            selectedCategoryID: selectedCategoryID
                          ),
                          index.categoryIncludedInTotals(transaction.categoryID(for: movement)),
                          index.includesInTotals(accountID: movement.accountID),
                          let converted = financeConvertedMinorUnits(
                              movement.money,
                              to: selectedCurrency,
                              using: transaction.exchangeRate
                          ) else {
                        continue
                    }
                    accountNetAmounts[movement.accountID, default: 0] += converted
                }
                let refundCategoryID = transaction.categoryID
                    ?? transaction.outflows.first.flatMap { transaction.categoryID(for: $0) }
                for movement in transaction.inflows {
                    guard index.categoryMatches(
                            movement.categoryID ?? refundCategoryID,
                            selectedCategoryID: selectedCategoryID
                          ),
                          index.categoryIncludedInTotals(movement.categoryID ?? refundCategoryID),
                          index.includesInTotals(accountID: movement.accountID),
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
            .map { value in
                MetricsCategorySnapshot(
                    id: "\(value.categoryID?.uuidString ?? "uncategorized")-\(selectedCurrency.rawValue)",
                    categoryID: value.categoryID,
                    title: value.title,
                    currency: selectedCurrency,
                    amount: value.amount,
                    count: value.count
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
            .map { value in
                MetricsAccountSnapshot(
                    id: "\(value.accountID.uuidString)-\(selectedCurrency.rawValue)",
                    accountID: value.accountID,
                    title: value.title,
                    currency: selectedCurrency,
                    amount: value.amount,
                    count: value.count
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
                  index.transactionMatchesCategory(
                    transaction,
                    selectedCategoryID: categoryID
                  ),
                  index.transactionCategoryIncludedInTotals(
                    transaction,
                    selectedCategoryID: categoryID
                  ) else {
                continue
            }

            let amounts = index.expenseAmountsByCategory(transaction, currency: selectedCurrency)
            for (movementCategoryID, amount) in amounts where amount != 0 {
                guard index.categoryMatches(movementCategoryID, selectedCategoryID: categoryID),
                      let subcategoryID = index.directDescendantCategoryID(
                        for: movementCategoryID,
                        under: categoryID
                      ) else {
                    continue
                }
                let current = totals[subcategoryID]
                    ?? (index.categoryName(for: subcategoryID), 0, 0)
                totals[subcategoryID] = (
                    current.title,
                    current.amount + amount,
                    current.count + 1
                )
            }
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
            .map { value in
                MetricsCategorySnapshot(
                    id: "detail-\(value.categoryID.uuidString)-\(selectedCurrency.rawValue)",
                    categoryID: value.categoryID,
                    title: value.title,
                    currency: selectedCurrency,
                    amount: value.amount,
                    count: value.count
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
    let topCategoryID: UUID?
    let recentTransactions: [LedgerTransaction]
    let upcomingSchedules: [ScheduledTransaction]
    let scheduledEntryCounts: [LedgerCurrency: Int]
    let scheduledChanges: [LedgerCurrency: Int64]
    let firstProjectedShortfalls: [LedgerCurrency: Date]
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
            topCategoryID: nil,
            recentTransactions: [],
            upcomingSchedules: [],
            scheduledEntryCounts: [:],
            scheduledChanges: [:],
            firstProjectedShortfalls: [:],
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
        var scheduledEntryCounts: [LedgerCurrency: Int] = [:]
        var scheduledChangesByDate: [Date: [LedgerCurrency: Int64]] = [:]
        for schedule in upcomingSchedules where schedule.nextRunDate <= horizon {
            let occurrences = schedule.occurrences(through: horizon, calendar: calendar)
                .filter { $0 >= date }
            guard !occurrences.isEmpty else { continue }

            var changes: [LedgerCurrency: Int64] = [:]
            for (movements, sign) in [(schedule.inflows, Int64(1)), (schedule.outflows, Int64(-1))] {
                for movement in movements {
                    guard index.includesInTotals(accountID: movement.accountID),
                          let account = index.account(with: movement.accountID),
                          let amount = financeConvertedMinorUnits(
                              movement.money, to: account.currency, using: schedule.exchangeRate
                          ) else { continue }
                    changes[account.currency, default: 0] += sign * amount
                }
            }
            for (currency, change) in changes {
                scheduledEntryCounts[currency, default: 0] += occurrences.count
                for occurrence in occurrences {
                    scheduledChangesByDate[occurrence, default: [:]][currency, default: 0] += change
                }
            }
        }

        let availableBalances = Dictionary(uniqueKeysWithValues: LedgerCurrency.allCases.map {
            ($0, index.availableBalance(for: $0))
        })
        var scheduledChanges: [LedgerCurrency: Int64] = [:]
        var firstProjectedShortfalls: [LedgerCurrency: Date] = [:]
        for (occurrence, changes) in scheduledChangesByDate.sorted(by: { $0.key < $1.key }) {
            for (currency, change) in changes {
                let totalChange = scheduledChanges[currency, default: 0] + change
                scheduledChanges[currency] = totalChange
                if firstProjectedShortfalls[currency] == nil,
                   (availableBalances[currency]?.minorUnits ?? 0) + totalChange < 0 {
                    firstProjectedShortfalls[currency] = occurrence
                }
            }
        }

        let month = calendar.dateInterval(of: .month, for: date)
        var categoryCounts: [UUID: Int] = [:]
        var monthTransactionCount = 0
        for transaction in index.sortedTransactions where month.map({
            transaction.date >= $0.start && transaction.date < $0.end
        }) == true {
            if index.transactionHasIncludedAccount(transaction) {
                monthTransactionCount += 1
            }
            guard transaction.kind == .expense,
                  index.transactionCategoryIncludedInTotals(transaction) else {
                continue
            }
            for categoryID in Set(index.categoryIDs(for: transaction).compactMap { $0 }) {
                categoryCounts[categoryID, default: 0] += 1
            }
        }

        return DashboardSnapshot(
            attentionItems: attentionItems,
            availableBalances: availableBalances,
            activeAccounts: activeAccounts,
            includedAccountCount: includedAccountCount,
            excludedAccountCount: activeAccounts.count - includedAccountCount,
            monthExpenses: index.monthlyExpenseTotals(for: date, calendar: calendar),
            monthTransactionCount: monthTransactionCount,
            topCategoryID: categoryCounts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return (index.categoryPath(for: lhs.key)) > (index.categoryPath(for: rhs.key))
            }?.key,
            recentTransactions: index.sortedTransactions,
            upcomingSchedules: upcomingSchedules,
            scheduledEntryCounts: scheduledEntryCounts,
            scheduledChanges: scheduledChanges,
            firstProjectedShortfalls: firstProjectedShortfalls,
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
