import Foundation
import SwiftUI

enum FinanceSearch {
    static func matches(_ account: Account, query: String, balance: Money) -> Bool {
        let searchable = [
            account.name,
            account.type.displayName,
            account.currency.rawValue,
            balance.formatted,
            account.isArchived ? "Archived" : "Active"
        ].joined(separator: " ")
        return searchable.localizedCaseInsensitiveContains(query)
    }

    static func matches(_ category: LedgerCategory, query: String, index: LedgerIndex) -> Bool {
        index.categoryPath(for: category.id).localizedCaseInsensitiveContains(query)
    }

    static func matches(_ transaction: LedgerTransaction, query: String, index: LedgerIndex) -> Bool {
        searchableText(for: transaction, index: index).localizedCaseInsensitiveContains(query)
    }

    static func searchableText(for transaction: LedgerTransaction, index: LedgerIndex) -> String {
        let movements = transaction.outflows + transaction.inflows
        var searchable = [
            transaction.note,
            index.categoryPath(for: transaction.categoryID),
            transaction.kind.displayName,
            transaction.date.formatted(.dateTime.year().month().day())
        ]

        searchable.append(contentsOf: movements.flatMap { movement in
            var details = [movement.money.formatted, movement.money.currency.rawValue]
            if let account = index.account(with: movement.accountID) {
                details.append("\(account.name) \(account.type.displayName) \(account.currency.rawValue)")
            }
            return details
        })

        if let amountDue = transaction.amountDue {
            searchable.append(amountDue.formatted)
        }
        if let exchangeRate = transaction.exchangeRate {
            searchable.append(exchangeRate.summary)
        }
        if let change = transaction.changeAdjustment {
            searchable.append(change.requested.formatted)
            searchable.append(change.actual.formatted)
        }

        return searchable.joined(separator: " ")
    }
}

private struct GlobalSearchTransactionDocument {
    let transaction: LedgerTransaction
    let searchableText: String
}

private struct GlobalSearchSnapshot {
    let accounts: [Account]
    let categories: [LedgerCategory]
    let transactions: [LedgerTransaction]
    let transactionCount: Int

    static let empty = GlobalSearchSnapshot(
        accounts: [],
        categories: [],
        transactions: [],
        transactionCount: 0
    )

    static func make(
        query: String,
        accounts: [Account],
        categories: [LedgerCategory],
        transactionDocuments: [GlobalSearchTransactionDocument],
        index: LedgerIndex,
        transactionLimit: Int = 25
    ) -> GlobalSearchSnapshot {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .empty }

        var matchingTransactions: [LedgerTransaction] = []
        var transactionCount = 0
        for document in transactionDocuments where document.searchableText.localizedCaseInsensitiveContains(query) {
            transactionCount += 1
            if matchingTransactions.count < transactionLimit {
                matchingTransactions.append(document.transaction)
            }
        }
        return GlobalSearchSnapshot(
            accounts: accounts.filter {
                FinanceSearch.matches($0, query: query, balance: index.balance(for: $0))
            },
            categories: categories.filter { FinanceSearch.matches($0, query: query, index: index) },
            transactions: matchingTransactions,
            transactionCount: transactionCount
        )
    }
}

@MainActor
struct GlobalSearchView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @Binding var searchText: String
    @State private var results = GlobalSearchSnapshot.empty
    @State private var transactionDocuments: [GlobalSearchTransactionDocument] = []
    @State private var transactionDocumentsRevision: Int?
    @State private var editingTransaction: LedgerTransaction?
    @State private var transactionToTemplate: LedgerTransaction?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskID: String {
        "\(store.ledgerRevision)|\(query)"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            PocketGlassContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "Search your ledger",
                            systemImage: "magnifyingglass",
                            description: Text("Find accounts, transactions, descriptions, categories, amounts, and currencies.")
                        )
                        .padding(.top, 18)
                    } else if results.isEmpty {
                        ContentUnavailableView(
                            "No results",
                            systemImage: "magnifyingglass",
                            description: Text("Try another name, description, category, amount, or currency.")
                        )
                        .padding(.top, 18)
                    } else {
                        if !results.accounts.isEmpty {
                            resultsSection(title: "Accounts", count: results.accounts.count) {
                                ForEach(results.accounts) { account in
                                    NavigationLink {
                                        AccountDetailView(store: store, security: security, accountID: account.id)
                                    } label: {
                                        SearchAccountRow(
                                            account: account,
                                            balance: store.balance(for: account),
                                            areBalancesRevealed: areBalancesRevealed
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    if account.id != results.accounts.last?.id {
                                        Divider().overlay(PocketLedgerTheme.divider)
                                    }
                                }
                            }
                        }

                        if !results.categories.isEmpty {
                            resultsSection(title: "Categories", count: results.categories.count) {
                                ForEach(results.categories) { category in
                                    NavigationLink {
                                        TransactionsView(
                                            store: store,
                                            initialSearch: store.categoryPath(for: category.id)
                                        )
                                    } label: {
                                        SearchCategoryRow(
                                            category: category,
                                            path: store.categoryPath(for: category.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    if category.id != results.categories.last?.id {
                                        Divider().overlay(PocketLedgerTheme.divider)
                                    }
                                }
                            }
                        }

                        if !results.transactions.isEmpty {
                            resultsSection(title: "Transactions", count: results.transactionCount) {
                                ForEach(results.transactions) { transaction in
                                    TransactionRow(
                                        transaction: transaction,
                                        store: store,
                                        onEdit: { editingTransaction = transaction },
                                        onDuplicate: { _ = store.duplicateTransaction(id: transaction.id) },
                                        onDelete: { _ = store.deleteTransaction(id: transaction.id) },
                                        onSaveTemplate: { transactionToTemplate = transaction },
                                        allowsActions: true,
                                        subtitleOverride: transactionSubtitle(transaction),
                                        usesScrollSwipeActions: true
                                    )
                                    if transaction.id != results.transactions.last?.id {
                                        Divider().overlay(PocketLedgerTheme.divider)
                                    }
                                }

                                if results.transactionCount > results.transactions.count {
                                    NavigationLink {
                                        TransactionsView(store: store, initialSearch: query)
                                    } label: {
                                        Label("See all matching transactions", systemImage: "arrow.right")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(PocketLedgerTheme.accent)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 12)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .pocketSwipeActionsContainer()
        .pocketScreen()
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .task(id: searchTaskID) {
            await refreshResults(for: query)
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionEditor(store: store, transaction: transaction)
        }
        .sheet(item: $transactionToTemplate) { transaction in
            TemplateNameEditor(store: store, transaction: transaction)
        }
    }

    private func resultsSection<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }

            LazyVStack(spacing: 0, content: content)
                .padding(.horizontal, 14)
                .pocketGroupedSurface(cornerRadius: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(PocketLedgerTheme.divider, lineWidth: 1)
                }
        }
    }

    private func refreshResults(for query: String) async {
        guard !query.isEmpty else {
            results = .empty
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        let index = store.ledgerIndex
        let revision = store.ledgerRevision
        if transactionDocumentsRevision != revision {
            transactionDocuments = index.sortedTransactions.map { transaction in
                GlobalSearchTransactionDocument(
                    transaction: transaction,
                    searchableText: FinanceSearch.searchableText(for: transaction, index: index)
                )
            }
            transactionDocumentsRevision = revision
        }

        results = GlobalSearchSnapshot.make(
            query: query,
            accounts: store.data.accounts,
            categories: store.data.categories,
            transactionDocuments: transactionDocuments,
            index: index
        )
    }

    private func transactionSubtitle(_ transaction: LedgerTransaction) -> String {
        let accountNames = (transaction.outflows + transaction.inflows)
            .compactMap { store.account(with: $0.accountID)?.name }
            .joined(separator: ", ")
        return [
            store.categoryPath(for: transaction.categoryID),
            accountNames,
            transaction.date.formatted(.dateTime.month(.abbreviated).day().year())
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
}

private extension GlobalSearchSnapshot {
    var isEmpty: Bool {
        accounts.isEmpty && categories.isEmpty && transactions.isEmpty
    }
}

private struct SearchAccountRow: View {
    let account: Account
    let balance: Money
    let areBalancesRevealed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.type.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PocketLedgerTheme.accent)
                .frame(width: 36, height: 36)
                .pocketGlassSurface(cornerRadius: 18, tint: PocketLedgerTheme.accent.opacity(0.12))

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(account.type.displayName) · \(account.currency.rawValue)\(account.isArchived ? " · Archived" : "")")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            ProtectedAmountText(value: balance.formatted, isRevealed: areBalancesRevealed)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(PocketLedgerTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
private struct SearchCategoryRow: View {
    let category: LedgerCategory
    let path: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PocketLedgerTheme.accent)
                .frame(width: 36, height: 36)
                .pocketGlassSurface(cornerRadius: 18, tint: PocketLedgerTheme.accent.opacity(0.12))

            VStack(alignment: .leading, spacing: 3) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(path)\(category.isArchived ? " · Archived" : "")")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
