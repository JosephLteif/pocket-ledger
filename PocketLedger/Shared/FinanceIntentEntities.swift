import AppIntents
import CoreSpotlight
import Foundation

struct FinanceAccountEntity: IndexedEntity, Hashable, Sendable {
    let id: UUID
    @Property(title: "Account name") var name: String
    @Property(title: "Currency") var currency: String
    @Property(title: "Account type") var accountType: String
    @Property(title: "Current balance") var balance: String

    init(account: Account) {
        self.init(account: account, balance: account.openingBalance)
    }

    init(account: Account, balance: Money) {
        id = account.id
        name = account.name
        currency = account.currency.rawValue
        accountType = account.type.displayName
        self.balance = balance.formatted
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(currency) · \(accountType) · \(balance)"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(itemContentType: "public.text")
        attributes.title = name
        attributes.contentDescription = "\(name), \(accountType), \(currency), balance \(balance)"
        attributes.keywords = [name, currency, accountType, balance]
        return attributes
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = FinanceAccountQuery()

    static func == (lhs: FinanceAccountEntity, rhs: FinanceAccountEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct FinanceCategoryEntity: IndexedEntity, Hashable, Sendable {
    let id: UUID
    @Property(title: "Category name") var name: String
    @Property(title: "Category path") var path: String

    init(category: LedgerCategory, categories: [LedgerCategory]) {
        id = category.id
        name = category.name
        path = financeCategoryPath(for: category.id, in: categories)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(path)", subtitle: "Category")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(itemContentType: "public.text")
        attributes.title = path
        attributes.contentDescription = "Pocket Ledger category \(path)"
        attributes.keywords = [name, path]
        return attributes
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static let defaultQuery = FinanceCategoryQuery()

    static func == (lhs: FinanceCategoryEntity, rhs: FinanceCategoryEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct FinanceAccountQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [FinanceAccountEntity.ID]) async throws -> [FinanceAccountEntity] {
        let data = FinanceStorage(context: "app-intent").load()
        return identifiers.compactMap { identifier in
            data.accounts.first(where: { $0.id == identifier && !$0.isArchived }).map {
                FinanceAccountEntity(
                    account: $0,
                    balance: financeAccountBalance(for: $0, in: data)
                )
            }
        }
    }

    func suggestedEntities() async throws -> [FinanceAccountEntity] {
        allEntities()
    }

    func entities(matching string: String) async throws -> [FinanceAccountEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedEntities()
        }

        return allEntities().filter { account in
            account.name.localizedCaseInsensitiveContains(query)
                || account.currency.localizedCaseInsensitiveContains(query)
                || account.accountType.localizedCaseInsensitiveContains(query)
        }
    }

    private func allEntities() -> [FinanceAccountEntity] {
        let data = FinanceStorage(context: "app-intent").load()
        return data.accounts
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                FinanceAccountEntity(
                    account: $0,
                    balance: financeAccountBalance(for: $0, in: data)
                )
            }
    }

}

struct FinanceCategoryQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [FinanceCategoryEntity.ID]) async throws -> [FinanceCategoryEntity] {
        let data = FinanceStorage(context: "app-intent").load()
        return identifiers.compactMap { identifier in
            data.categories.first(where: { $0.id == identifier }).map {
                FinanceCategoryEntity(category: $0, categories: data.categories)
            }
        }
    }

    func suggestedEntities() async throws -> [FinanceCategoryEntity] {
        allEntities()
    }

    func entities(matching string: String) async throws -> [FinanceCategoryEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedEntities()
        }

        return allEntities().filter { category in
            category.name.localizedCaseInsensitiveContains(query)
                || category.path.localizedCaseInsensitiveContains(query)
        }
    }

    private func allEntities() -> [FinanceCategoryEntity] {
        let data = FinanceStorage(context: "app-intent").load()
        return data.categories
            .filter { !$0.isArchived }
            .map { FinanceCategoryEntity(category: $0, categories: data.categories) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

}

struct FinanceSavingsGoalEntity: AppEntity, Hashable, Sendable {
    let id: UUID
    @Property(title: "Goal name") var name: String
    @Property(title: "Current amount") var currentAmount: String
    @Property(title: "Target amount") var targetAmount: String

    init(goal: SavingsGoal) {
        id = goal.id
        name = goal.name
        currentAmount = goal.currentAmount.formatted
        targetAmount = goal.targetAmount.formatted
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(currentAmount) of \(targetAmount)")
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Savings Goal"
    static let defaultQuery = FinanceSavingsGoalQuery()

    static func == (lhs: FinanceSavingsGoalEntity, rhs: FinanceSavingsGoalEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct FinanceSavingsGoalQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [FinanceSavingsGoalEntity.ID]) async throws -> [FinanceSavingsGoalEntity] {
        let entities = allEntities()
        return identifiers.compactMap { identifier in entities.first(where: { $0.id == identifier }) }
    }

    func suggestedEntities() async throws -> [FinanceSavingsGoalEntity] {
        allEntities()
    }

    func entities(matching string: String) async throws -> [FinanceSavingsGoalEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return allEntities().filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func allEntities() -> [FinanceSavingsGoalEntity] {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else { return [] }
        let data = storage.load()
        guard !storage.isCorrupted else { return [] }
        return data.savingsGoals
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(FinanceSavingsGoalEntity.init(goal:))
    }
}

struct FinanceTemplateEntity: AppEntity, Hashable, Sendable {
    let id: UUID
    @Property(title: "Template name") var name: String
    @Property(title: "Transaction type") var kind: String
    @Property(title: "Note") var note: String
    @Property(title: "Amount") var amount: String

    init(template: LedgerTemplate) {
        id = template.id
        name = template.name
        kind = template.kind.displayName
        note = template.note
        amount = financeIntentMovementSummary(for: template.transactionTemplate)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind) · \(amount)")
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction Template"
    static let defaultQuery = FinanceTemplateQuery()

    static func == (lhs: FinanceTemplateEntity, rhs: FinanceTemplateEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct FinanceTemplateQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [FinanceTemplateEntity.ID]) async throws -> [FinanceTemplateEntity] {
        let entities = allEntities()
        return identifiers.compactMap { identifier in entities.first(where: { $0.id == identifier }) }
    }

    func suggestedEntities() async throws -> [FinanceTemplateEntity] {
        allEntities()
    }

    func entities(matching string: String) async throws -> [FinanceTemplateEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return allEntities().filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || $0.kind.localizedCaseInsensitiveContains(query)
        }
    }

    private func allEntities() -> [FinanceTemplateEntity] {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else { return [] }
        let data = storage.load()
        guard !storage.isCorrupted else { return [] }
        return data.templates
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(FinanceTemplateEntity.init(template:))
    }
}

enum FinanceIntentTransactionKind: String, AppEnum, CaseIterable, Hashable, Sendable {
    case expense
    case income
    case transfer

    var ledgerKind: TransactionKind {
        switch self {
        case .expense:
            return .expense
        case .income:
            return .income
        case .transfer:
            return .transfer
        }
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction type"
    static let caseDisplayRepresentations: [FinanceIntentTransactionKind: DisplayRepresentation] = [
        .expense: DisplayRepresentation(title: "Expense"),
        .income: DisplayRepresentation(title: "Income"),
        .transfer: DisplayRepresentation(title: "Transfer")
    ]
}

enum FinanceIntentCurrency: String, AppEnum, CaseIterable, Hashable, Sendable {
    case usd = "USD"
    case lbp = "LBP"
    case eur = "EUR"

    var ledgerCurrency: LedgerCurrency {
        switch self {
        case .usd:
            return .usd
        case .lbp:
            return .lbp
        case .eur:
            return .eur
        }
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Currency"
    static let caseDisplayRepresentations: [FinanceIntentCurrency: DisplayRepresentation] = [
        .usd: DisplayRepresentation(title: "USD", subtitle: "US Dollar"),
        .lbp: DisplayRepresentation(title: "LBP", subtitle: "Lebanese Pound"),
        .eur: DisplayRepresentation(title: "EUR", subtitle: "Euro")
    ]
}

func financeCategoryPath(for categoryID: UUID, in categories: [LedgerCategory]) -> String {
    var names: [String] = []
    var currentID: UUID? = categoryID
    var visited: Set<UUID> = []

    while let id = currentID,
          !visited.contains(id),
          let category = categories.first(where: { $0.id == id }) {
        visited.insert(id)
        names.insert(category.name, at: 0)
        currentID = category.parentID
    }

    return names.isEmpty ? "Uncategorized" : names.joined(separator: " / ")
}

func financeAccountBalance(for account: Account, in data: FinanceData) -> Money {
    var minorUnits = account.openingBalance.minorUnits

    for transaction in data.transactions {
        for movement in transaction.outflows where movement.accountID == account.id {
            guard let amount = financeConvertedMinorUnits(
                movement.money,
                to: account.currency,
                using: transaction.exchangeRate
            ) else { continue }
            minorUnits -= amount
        }
        for movement in transaction.inflows where movement.accountID == account.id {
            guard let amount = financeConvertedMinorUnits(
                movement.money,
                to: account.currency,
                using: transaction.exchangeRate
            ) else { continue }
            minorUnits += amount
        }
    }

    return Money(currency: account.currency, minorUnits: minorUnits)
}
