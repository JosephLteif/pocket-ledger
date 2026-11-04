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

enum FinanceUpcomingCommitmentPeriod: String, AppEnum, CaseIterable, Hashable, Sendable {
    case today
    case thisWeek
    case next7Days
    case next30Days

    var displayName: String {
        switch self {
        case .today: "today"
        case .thisWeek: "this week"
        case .next7Days: "in the next 7 days"
        case .next30Days: "in the next 30 days"
        }
    }

    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .next7Days, .next30Days:
            let days = self == .next7Days ? 7 : 30
            let start = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Upcoming period"
    static let caseDisplayRepresentations: [FinanceUpcomingCommitmentPeriod: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today"),
        .thisWeek: DisplayRepresentation(title: "This week"),
        .next7Days: DisplayRepresentation(title: "In the next 7 days"),
        .next30Days: DisplayRepresentation(title: "In the next 30 days")
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

#if POCKET_LEDGER_APP_TARGET
@AppIntent(.tool)
#endif
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

#if POCKET_LEDGER_APP_TARGET
@AppIntent(.tool)
#endif
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

#if POCKET_LEDGER_APP_TARGET
@AppIntent(.tool)
#endif
struct GetUpcomingCommitmentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Upcoming Commitments"
    static let description = IntentDescription("Lists upcoming scheduled transactions and loan due dates, including overdue items.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Period", description: "Show commitments due in this period, plus overdue items.")
    var period: FinanceUpcomingCommitmentPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("List Pocket Ledger commitments due \(\.$period)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(value: "Ledger unavailable", dialog: "Pocket Ledger's saved data is unavailable.")
        }
        let data = storage.load()
        guard !storage.isCorrupted else {
            return .result(value: "Ledger unavailable", dialog: "Pocket Ledger could not read the saved commitments.")
        }
        guard let interval = period.interval() else {
            return .result(value: "Invalid period", dialog: "Pocket Ledger could not determine that date range.")
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var commitments: [(date: Date, isOverdue: Bool, detail: String)] = []

        for schedule in data.scheduledTransactions where schedule.isEnabled {
            let date = calendar.startOfDay(for: schedule.nextRunDate)
            let isOverdue = date < today
            guard isOverdue || (date >= interval.start && date < interval.end) else { continue }

            let note = schedule.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = note.isEmpty ? schedule.kind.displayName : note
            let accountNames = Set((schedule.outflows + schedule.inflows).map(\.accountID))
                .compactMap { accountID in data.accounts.first(where: { $0.id == accountID })?.name }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let accounts = accountNames.isEmpty ? "" : " in \(accountNames.joined(separator: ", "))"
            let amount = financeIntentMovementSummary(for: schedule.transactionTemplate)
            commitments.append((date, isOverdue, "\(title): \(amount)\(accounts)"))
        }

        for loan in data.loans where !loan.isSettled {
            guard let dueDate = loan.dueDate else { continue }
            let date = calendar.startOfDay(for: dueDate)
            let isOverdue = date < today
            guard isOverdue || (date >= interval.start && date < interval.end) else { continue }

            let title = loan.direction == .borrowed
                ? "Loan payment to \(loan.counterparty)"
                : "Loan payment from \(loan.counterparty)"
            commitments.append((date, isOverdue, "\(title): \(loan.outstandingAmount.formatted)"))
        }

        commitments.sort { $0.date < $1.date }
        guard !commitments.isEmpty else {
            let message = "No overdue commitments or payments due \(period.displayName)."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }

        let lines = commitments.prefix(10).map { commitment in
            let date = commitment.date.formatted(date: .abbreviated, time: .omitted)
            let prefix = commitment.isOverdue ? "Overdue" : "Due \(date)"
            return "\(prefix): \(commitment.detail)"
        }
        let remainingCount = commitments.count - lines.count
        let suffix = remainingCount > 0 ? "\nAnd \(remainingCount) more." : ""
        let summary = lines.joined(separator: "\n") + suffix
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

#if POCKET_LEDGER_APP_TARGET
@AppIntent(.tool)
#endif
struct GetSavingsGoalProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Pocket Ledger Savings Goals"
    static let description = IntentDescription("Reads current progress, remaining amounts, and the monthly pace for saved savings goals with a target date.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Savings goal", description: "Choose one goal, or leave blank to summarize all goals.")
    var goal: FinanceSavingsGoalEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check Pocket Ledger savings goal progress")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(value: "Ledger unavailable", dialog: "Pocket Ledger's saved data is unavailable.")
        }
        let data = storage.load()
        guard !storage.isCorrupted else {
            return .result(value: "Ledger unavailable", dialog: "Pocket Ledger could not read the saved savings goals.")
        }

        let goals: [SavingsGoal]
        if let goal {
            guard let resolvedGoal = data.savingsGoals.first(where: { $0.id == goal.id }) else {
                return .result(value: "Goal unavailable", dialog: "Pocket Ledger could not find that savings goal.")
            }
            goals = [resolvedGoal]
        } else {
            goals = data.savingsGoals.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        guard !goals.isEmpty else {
            return .result(value: "No savings goals", dialog: "You haven't set up any savings goals in Pocket Ledger yet.")
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let summaries = goals.map { goal in
            let remainingUnits = max(goal.targetAmount.minorUnits - goal.currentAmount.minorUnits, 0)
            let remaining = Money(currency: goal.targetAmount.currency, minorUnits: remainingUnits)
            if remainingUnits == 0 {
                return "\(goal.name): complete at \(goal.targetAmount.formatted)."
            }

            var summary = "\(goal.name): \(goal.currentAmount.formatted) of \(goal.targetAmount.formatted), \(remaining.formatted) remaining"
            guard let targetDate = goal.targetDate else {
                return summary + ". No target date is set."
            }

            summary += ", target date \(targetDate.formatted(date: .abbreviated, time: .omitted))"
            guard calendar.startOfDay(for: targetDate) >= today else {
                return summary + ". The target date has passed."
            }
            guard let currentMonth = calendar.dateInterval(of: .month, for: today)?.start,
                  let targetMonth = calendar.dateInterval(of: .month, for: targetDate)?.start else {
                return summary + "."
            }

            let monthDistance = calendar.dateComponents([.month], from: currentMonth, to: targetMonth).month ?? 0
            let monthsRemaining = max(monthDistance + 1, 1)
            let divisor = Int64(monthsRemaining)
            let monthlyUnits = remainingUnits / divisor + (remainingUnits % divisor == 0 ? 0 : 1)
            let monthlyAmount = Money(currency: goal.targetAmount.currency, minorUnits: monthlyUnits)
            let monthLabel = monthsRemaining == 1 ? "month" : "months"
            return summary + ". Save at least \(monthlyAmount.formatted) per month for \(monthsRemaining) \(monthLabel) to reach it by then."
        }
        let summary = summaries.joined(separator: "\n")
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
