import AppIntents
import Combine
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FinanceIntentSearchRouter: ObservableObject {
    static let shared = FinanceIntentSearchRouter()

    struct SearchRequest: Equatable {
        let id: UUID
        let query: String
    }

    @Published private(set) var pendingSearch: SearchRequest?

    func showSearch(for query: String) {
        pendingSearch = SearchRequest(id: UUID(), query: query)
    }

    func consumePendingSearch() -> SearchRequest? {
        defer { pendingSearch = nil }
        return pendingSearch
    }
}

private struct FinanceTransactionIntentSearchIndex {
    private let accountNamesByID: [UUID: [String]]
    private let categoriesByID: [UUID: LedgerCategory]

    init(data: FinanceData) {
        var accountNamesByID: [UUID: [String]] = [:]
        for account in data.accounts {
            accountNamesByID[account.id, default: []].append(account.name)
        }
        self.accountNamesByID = accountNamesByID

        var categoriesByID: [UUID: LedgerCategory] = [:]
        for category in data.categories {
            if categoriesByID[category.id] == nil {
                categoriesByID[category.id] = category
            }
        }
        self.categoriesByID = categoriesByID
    }

    func matches(_ transaction: LedgerTransaction, query: String) -> Bool {
        if transaction.note.localizedCaseInsensitiveContains(query)
            || transaction.kind.displayName.localizedCaseInsensitiveContains(query)
            || transaction.date.formatted(date: .abbreviated, time: .omitted)
                .localizedCaseInsensitiveContains(query)
            || financeIntentMovementSummary(for: transaction).localizedCaseInsensitiveContains(query) {
            return true
        }

        let category = transaction.categoryID.map { categoryPath(for: $0) } ?? "Uncategorized"
        if category.localizedCaseInsensitiveContains(query) {
            return true
        }

        let accountIDs = Set((transaction.outflows + transaction.inflows).map(\.accountID))
        let accountNames = accountIDs
            .flatMap { accountNamesByID[$0] ?? [] }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: ", ")
        return accountNames.localizedCaseInsensitiveContains(query)
    }

    private func categoryPath(for categoryID: UUID) -> String {
        var names: [String] = []
        var currentID: UUID? = categoryID
        var visited: Set<UUID> = []

        while let id = currentID,
              !visited.contains(id),
              let category = categoriesByID[id] {
            visited.insert(id)
            names.insert(category.name, at: 0)
            currentID = category.parentID
        }

        return names.isEmpty ? "Uncategorized" : names.joined(separator: " / ")
    }
}

struct FinanceTransactionIntentValueQuery: IntentValueQuery {
    func values(for input: StringSearchCriteria) async throws -> [FinanceTransactionEntity] {
        let query = input.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else { return [] }

        let data = storage.load()
        guard !storage.isCorrupted else { return [] }

        let searchIndex = FinanceTransactionIntentSearchIndex(data: data)
        return Array(
            data.transactions
                .sorted { $0.date > $1.date }
                .lazy
                .filter { searchIndex.matches($0, query: query) }
                .prefix(25)
                .map { FinanceTransactionEntity(transaction: $0, data: data) }
        )
    }
}

struct FinanceAccountIntentValueQuery: IntentValueQuery {
    func values(for input: StringSearchCriteria) async throws -> [FinanceAccountEntity] {
        let query = input.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else { return [] }

        let data = storage.load()
        guard !storage.isCorrupted else { return [] }

        let matches = data.accounts
            .filter { !$0.isArchived }
            .map { account in
                FinanceAccountEntity(
                    account: account,
                    balance: financeAccountBalance(for: account, in: data)
                )
            }
            .filter { account in
                [account.name, account.currency, account.accountType, account.balance]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return Array(matches.prefix(10))
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
#else
@available(iOS 17.0, *)
#endif
struct SearchPocketLedgerIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Pocket Ledger"
    static let description = IntentDescription("Search saved accounts, categories, and transactions in Pocket Ledger.")
    static let searchScopes: [StringSearchScope] = [.general]
    static let openAppWhenRun = true

#if compiler(>=6.4)
    var criteria: StringSearchCriteria
#else
    @Parameter var criteria: StringSearchCriteria
#endif

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            FinanceIntentSearchRouter.shared.showSearch(for: criteria.term)
        }
        return .result()
    }
}

extension FinanceTransactionEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { entity in
            let details = [
                "Transaction: \(entity.note.isEmpty ? entity.kind : entity.note)",
                "Type: \(entity.kind)",
                "Date: \(entity.date.formatted(date: .abbreviated, time: .shortened))",
                "Amount: \(entity.amount)",
                "Category: \(entity.category)",
                "Accounts: \(entity.accountNames)"
            ]
            return Data(details.joined(separator: "\n").utf8)
        }
    }
}

extension FinanceAccountEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { entity in
            Data(
                "Account: \(entity.name)\nType: \(entity.accountType)\nBalance: \(entity.balance)"
                    .utf8
            )
        }
    }
}
