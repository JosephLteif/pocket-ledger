import AppIntents
import CoreSpotlight
import Foundation

let financeIntentSearchIndexName = "PocketLedger.AppIntents"

enum FinanceDateRange: String, AppEnum, CaseIterable, Hashable, Sendable {
    case today
    case yesterday
    case last7Days
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case thisYear
    case allTime

    var displayName: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .last7Days:
            return "The last 7 days"
        case .thisWeek:
            return "This week"
        case .lastWeek:
            return "Last week"
        case .thisMonth:
            return "This month"
        case .lastMonth:
            return "Last month"
        case .thisYear:
            return "This year"
        case .allTime:
            return "All time"
        }
    }

    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .yesterday:
            guard let date = calendar.date(byAdding: .day, value: -1, to: now) else {
                return nil
            }
            return calendar.dateInterval(of: .day, for: date)
        case .last7Days:
            let todayStart = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -6, to: todayStart),
                  let end = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
                return nil
            }
            return DateInterval(start: start, end: end)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek:
            guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start) else {
                return nil
            }
            return DateInterval(start: start, end: currentWeek.start)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let currentMonth = calendar.dateInterval(of: .month, for: now),
                  let start = calendar.date(byAdding: .month, value: -1, to: currentMonth.start) else {
                return nil
            }
            return DateInterval(start: start, end: currentMonth.start)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)
        case .allTime:
            return nil
        }
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Date range"
    static let caseDisplayRepresentations: [FinanceDateRange: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today"),
        .yesterday: DisplayRepresentation(title: "Yesterday"),
        .last7Days: DisplayRepresentation(title: "The last 7 days"),
        .thisWeek: DisplayRepresentation(title: "This week"),
        .lastWeek: DisplayRepresentation(title: "Last week"),
        .thisMonth: DisplayRepresentation(title: "This month"),
        .lastMonth: DisplayRepresentation(title: "Last month"),
        .thisYear: DisplayRepresentation(title: "This year"),
        .allTime: DisplayRepresentation(title: "All time")
    ]
}

struct FinanceTransactionEntity: IndexedEntity, Hashable, Sendable {
    let id: UUID
    @Property(title: "Date") var date: Date
    @Property(title: "Note") var note: String
    @Property(title: "Transaction type") var kind: String
    @Property(title: "Category") var category: String
    @Property(title: "Amount") var amount: String
    @Property(title: "Accounts") var accountNames: String

    init(transaction: LedgerTransaction, data: FinanceData) {
        id = transaction.id
        date = transaction.date
        note = transaction.note
        kind = transaction.kind.displayName
        category = transaction.categoryID
            .map { financeCategoryPath(for: $0, in: data.categories) }
            ?? "Uncategorized"
        amount = financeIntentMovementSummary(for: transaction)

        let accountIDs = Set((transaction.outflows + transaction.inflows).map(\.accountID))
        accountNames = data.accounts
            .filter { accountIDs.contains($0.id) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: ", ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(note.isEmpty ? kind : note)",
            subtitle: "\(kind) · \(amount) · \(date.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    func matchesSearch(_ query: String) -> Bool {
        [note, kind, category, amount, accountNames]
            .contains { $0.localizedCaseInsensitiveContains(query) }
            || date.formatted(date: .abbreviated, time: .omitted)
                .localizedCaseInsensitiveContains(query)
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(itemContentType: "public.text")
        attributes.title = note.isEmpty ? kind : note
        attributes.contentDescription = "\(kind), \(amount), \(category), \(accountNames), \(date.formatted(date: .abbreviated, time: .shortened))"
        attributes.keywords = [note, kind, category, amount, accountNames]
            .filter { !$0.isEmpty }
        attributes.startDate = date
        attributes.endDate = date
        return attributes
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction"
    static let defaultQuery = FinanceTransactionQuery()

    static func == (lhs: FinanceTransactionEntity, rhs: FinanceTransactionEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct FinanceTransactionQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [FinanceTransactionEntity.ID]) async throws -> [FinanceTransactionEntity] {
        let data = FinanceStorage(context: "app-intent").load()
        return identifiers.compactMap { identifier in
            data.transactions.first(where: { $0.id == identifier }).map {
                FinanceTransactionEntity(transaction: $0, data: data)
            }
        }
    }

    func suggestedEntities() async throws -> [FinanceTransactionEntity] {
        Array(allEntities().prefix(25))
    }

    func entities(matching string: String) async throws -> [FinanceTransactionEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedEntities()
        }

        return allEntities().filter { $0.matchesSearch(query) }
    }

    private func allEntities() -> [FinanceTransactionEntity] {
        let data = FinanceStorage(context: "app-intent").load()
        return data.transactions
            .sorted { $0.date > $1.date }
            .map { FinanceTransactionEntity(transaction: $0, data: data) }
    }
}

struct GetTransactionHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Transaction History"
    static let description = IntentDescription("Returns Pocket Ledger transactions for a date range, category, or account.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Date range", description: "The period to search.")
    var period: FinanceDateRange

    @Parameter(title: "Category", description: "Optional category, including its subcategories.")
    var category: FinanceCategoryEntity?

    @Parameter(title: "Account", description: "Optional account involved in the transaction.")
    var account: FinanceAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Show Pocket Ledger transactions for \(\.$period)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[FinanceTransactionEntity]> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: [],
                dialog: "Pocket Ledger transaction history is unavailable because the persistent database is unavailable."
            )
        }

        let data = storage.load()
        let transactions = data.transactions
            .filter {
                financeTransaction(
                    $0,
                    matches: period,
                    categoryID: category?.id,
                    accountID: account?.id,
                    in: data
                )
            }
            .sorted { $0.date > $1.date }
        let entities = transactions.map { FinanceTransactionEntity(transaction: $0, data: data) }

        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: financeTransactionHistoryDialog(
                entities,
                period: period,
                category: category,
                account: account
            ))
        )
    }
}

struct GetSpendingSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Spending Summary"
    static let description = IntentDescription("Calculates Pocket Ledger expense totals for a date range, category, or account.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Date range", description: "The period to summarize.")
    var period: FinanceDateRange

    @Parameter(title: "Category", description: "Optional category, including its subcategories.")
    var category: FinanceCategoryEntity?

    @Parameter(title: "Account", description: "Optional account whose expenses should be included.")
    var account: FinanceAccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize Pocket Ledger spending for \(\.$period)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "Pocket Ledger spending is unavailable because the persistent database is unavailable."
            )
        }

        let summary = financeSpendingSummary(
            in: storage.load(),
            period: period,
            categoryID: category?.id,
            accountID: account?.id
        )
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

actor FinanceIntentIndexing {
    static let shared = FinanceIntentIndexing()
    private var isRefreshing = false
    private var refreshRequested = false

    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
        isRefreshing = false
    }

    private func performRefresh() async {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else { return }

        let data = storage.load()
        let index = CSSearchableIndex(name: financeIntentSearchIndexName)
        let accounts = data.accounts
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                FinanceAccountEntity(
                    account: $0,
                    balance: financeAccountBalance(for: $0, in: data)
                )
            }
        let categories = data.categories
            .filter { !$0.isArchived }
            .map { FinanceCategoryEntity(category: $0, categories: data.categories) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let transactions = data.transactions
            .sorted { $0.date > $1.date }
            .map { FinanceTransactionEntity(transaction: $0, data: data) }

        do {
            try await index.deleteAppEntities(ofType: FinanceAccountEntity.self)
            try await index.deleteAppEntities(ofType: FinanceCategoryEntity.self)
            try await index.deleteAppEntities(ofType: FinanceTransactionEntity.self)
            try await index.indexAppEntities(accounts, priority: 80)
            try await index.indexAppEntities(categories, priority: 60)
            try await index.indexAppEntities(transactions, priority: 100)
        } catch {
            // Spotlight indexing is best effort; ledger persistence remains authoritative.
        }
    }
}

func financeIntentMovementSummary(for transaction: LedgerTransaction) -> String {
    let outflowText = transaction.outflows.map { $0.money.formatted }.joined(separator: " + ")
    let inflowText = transaction.inflows.map { $0.money.formatted }.joined(separator: " + ")

    if outflowText.isEmpty {
        return "+ \(inflowText)"
    }
    if inflowText.isEmpty {
        return "− \(outflowText)"
    }
    return "\(outflowText) → \(inflowText)"
}

private func financeCategoryScope(for categoryID: UUID, in categories: [LedgerCategory]) -> Set<UUID> {
    var scope = [categoryID]
    var index = 0

    while index < scope.count {
        let parentID = scope[index]
        for category in categories where category.parentID == parentID && !scope.contains(category.id) {
            scope.append(category.id)
        }
        index += 1
    }

    return Set(scope)
}

private func financeTransaction(
    _ transaction: LedgerTransaction,
    matches period: FinanceDateRange,
    categoryID: UUID?,
    accountID: UUID?,
    in data: FinanceData
) -> Bool {
    if let interval = period.interval(),
       !(transaction.date >= interval.start && transaction.date < interval.end) {
        return false
    }

    if let categoryID {
        guard let transactionCategoryID = transaction.categoryID,
              financeCategoryScope(for: categoryID, in: data.categories).contains(transactionCategoryID) else {
            return false
        }
    }

    if let accountID,
       !(transaction.outflows + transaction.inflows).contains(where: { $0.accountID == accountID }) {
        return false
    }

    return true
}

private func financeTransactionHistoryDialog(
    _ transactions: [FinanceTransactionEntity],
    period: FinanceDateRange,
    category: FinanceCategoryEntity?,
    account: FinanceAccountEntity?
) -> String {
    let scope = [
        category.map { "in \($0.path)" },
        account.map { "for \($0.name)" }
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    let scopeText = scope.isEmpty ? "" : " \(scope)"

    guard !transactions.isEmpty else {
        return "No Pocket Ledger transactions were found for \(period.displayName.lowercased())\(scopeText)."
    }

    let preview = transactions.prefix(5).map {
        "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.amount)\($0.note.isEmpty ? "" : " — \($0.note)")"
    }.joined(separator: "; ")
    let suffix = transactions.count > 5 ? " Showing the five most recent." : ""
    return "Found \(transactions.count) Pocket Ledger transaction\(transactions.count == 1 ? "" : "s") for \(period.displayName.lowercased())\(scopeText). \(preview).\(suffix)"
}

private func financeSpendingSummary(
    in data: FinanceData,
    period: FinanceDateRange,
    categoryID: UUID?,
    accountID: UUID?
) -> String {
    let categoryScope = categoryID.map { financeCategoryScope(for: $0, in: data.categories) }
    let matchingTransactions = data.transactions.filter { transaction in
        guard transaction.kind == .expense,
              financeTransaction(
                  transaction,
                  matches: period,
                  categoryID: categoryID,
                  accountID: accountID,
                  in: data
              ),
              financeCategoryIncludedInTotals(transaction.categoryID, in: data.categories) else {
            return false
        }

        return transaction.outflows.contains { movement in
            (accountID != nil && movement.accountID == accountID)
                || (accountID == nil && data.accounts.first(where: { $0.id == movement.accountID })?.includeInTotals != false)
        }
    }

    var totals: [LedgerCurrency: Int64] = [:]
    var categoryCounts: [String: Int] = [:]
    var expenseCount = 0

    for transaction in matchingTransactions {
        let outflows = transaction.outflows.filter { movement in
            (accountID != nil && movement.accountID == accountID)
                || (accountID == nil && data.accounts.first(where: { $0.id == movement.accountID })?.includeInTotals != false)
        }
        guard !outflows.isEmpty else { continue }

        expenseCount += 1
        for movement in outflows {
            totals[movement.money.currency, default: 0] += movement.money.minorUnits
        }

        let categoryName: String
        if let transactionCategoryID = transaction.categoryID,
           categoryScope?.contains(transactionCategoryID) != false {
            categoryName = financeCategoryPath(for: transactionCategoryID, in: data.categories)
        } else {
            categoryName = "Uncategorized"
        }
        categoryCounts[categoryName, default: 0] += 1
    }

    let periodText = period.displayName.lowercased()
    let categoryText = categoryID.flatMap { financeCategoryPath(for: $0, in: data.categories) }
    let accountText = accountID.flatMap { accountID in data.accounts.first(where: { $0.id == accountID })?.name }
    let scope = [
        categoryText.map { "on \($0)" },
        accountText.map { "from \($0)" }
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    let scopeText = scope.isEmpty ? "" : " \(scope)"

    guard expenseCount > 0 else {
        return "No expenses were found \(periodText)\(scopeText)."
    }

    let totalText = LedgerCurrency.allCases.compactMap { currency -> String? in
        guard let minorUnits = totals[currency], minorUnits != 0 else { return nil }
        return Money(currency: currency, minorUnits: minorUnits).formatted
    }.joined(separator: " and ")
    let expenseLabel = expenseCount == 1 ? "expense" : "expenses"
    var summary = "\(period.displayName): \(expenseCount) \(expenseLabel)\(scopeText), totaling \(totalText)."

    if categoryID == nil, let topCategory = categoryCounts.max(by: { $0.value < $1.value }) {
        summary += " Most common category: \(topCategory.key) (\(topCategory.value) expense\(topCategory.value == 1 ? "" : "s"))."
    }

    return summary
}
