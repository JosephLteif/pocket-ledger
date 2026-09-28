import Foundation

#if os(iOS)
import WatchConnectivity
#endif

private struct WatchSyncDataInput: @unchecked Sendable {
    let data: FinanceData
}

private struct WatchSyncSnapshotOutput: @unchecked Sendable {
    let snapshot: WatchLedgerSnapshot
}

enum WatchSyncPublisher {
    static func isEligibleForDelivery(
        sessionSupported: Bool,
        isActivated: Bool,
        isWatchAppInstalled: Bool
    ) -> Bool {
        sessionSupported && isActivated && isWatchAppInstalled
    }

    static func makeSnapshot(from data: FinanceData, generatedAt: Date = .now) -> WatchLedgerSnapshot {
        let index = LedgerIndex(data: data)

        func categoryPath(for categoryID: UUID?) -> String? {
            guard let categoryID else { return nil }

            return index.categoryPath(for: categoryID)
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        let accountSummaries = data.accounts
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                WatchAccountSummary(
                    id: $0.id,
                    name: $0.name,
                    currency: $0.currency,
                    balance: index.balance(for: $0),
                    canUseForExpense: !$0.isArchived && $0.type != .loan
                )
            }

        let categorySummaries = data.categories
            .filter { !$0.isArchived }
            .compactMap { category in
                categoryPath(for: category.id).map {
                    WatchCategorySummary(id: category.id, path: $0)
                }
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }

        let transactionSummaries = data.transactions
            .sorted { $0.date > $1.date }
            .prefix(12)
            .compactMap { transaction -> WatchTransactionSummary? in
                guard let movement = (transaction.outflows + transaction.inflows).first,
                      let account = accountsByID[movement.accountID] else {
                    return nil
                }

                return WatchTransactionSummary(
                    id: transaction.id,
                    date: transaction.date,
                    note: transaction.note,
                    kind: transaction.kind.displayName,
                    amount: movement.money,
                    accountName: account.name,
                    categoryPath: categoryPath(for: transaction.categoryID)
                )
            }

        let balances = LedgerCurrency.allCases.map { currency in
            let totalMinorUnits = accountSummaries
                .filter { $0.currency == currency && $0.canUseForExpense }
                .reduce(Int64.zero) { $0 + $1.balance.minorUnits }
            return WatchBalanceSummary(
                currency: currency,
                balance: Money(currency: currency, minorUnits: totalMinorUnits)
            )
        }
        let attentionCount = data.transactions.filter {
            $0.kind == .expense && $0.categoryID == nil
        }.count
            + data.budgets.filter { budget in
                financeBudgetSpent(budget, in: data, using: index).minorUnits
                    > financeBudgetAllowance(budget, in: data, using: index).minorUnits
            }.count
        let upcomingScheduledCount = data.scheduledTransactions.filter {
            $0.isEnabled
                && $0.nextRunDate <= (Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now)
        }.count

        return WatchLedgerSnapshot(
            version: WatchLedgerSnapshot.currentVersion,
            generatedAt: generatedAt,
            balances: balances,
            accounts: accountSummaries,
            categories: categorySummaries,
            recentTransactions: Array(transactionSummaries),
            attentionCount: attentionCount,
            upcomingScheduledCount: upcomingScheduledCount
        )
    }

#if os(iOS)
    static func publish(data: FinanceData) {
        guard WCSession.isSupported() else { return }
        let input = WatchSyncDataInput(data: data)

        Task { @MainActor in
            let session = WCSession.default
            guard isEligibleForDelivery(
                sessionSupported: true,
                isActivated: session.activationState == .activated,
                isWatchAppInstalled: session.isWatchAppInstalled
            ) else { return }

            let output = await Task.detached(priority: .utility) {
                WatchSyncSnapshotOutput(snapshot: makeSnapshot(from: input.data))
            }.value
            guard isEligibleForDelivery(
                sessionSupported: true,
                isActivated: session.activationState == .activated,
                isWatchAppInstalled: session.isWatchAppInstalled
            ), let context = WatchSyncCodec.dictionary(for: output.snapshot) else { return }

            try? session.updateApplicationContext(context)
            if session.isComplicationEnabled {
                session.transferCurrentComplicationUserInfo(context)
            }
        }
    }
#endif
}
