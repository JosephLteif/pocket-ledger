import Foundation

enum ImportStep: Int, CaseIterable, Identifiable {
    case source
    case defaults
    case organize
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .source:
            return "Source & mapping"
        case .defaults:
            return "Defaults"
        case .organize:
            return "Accounts & categories"
        case .review:
            return "Review & import"
        }
    }

    var shortTitle: String {
        switch self {
        case .source:
            return "Source"
        case .defaults:
            return "Defaults"
        case .organize:
            return "Organize"
        case .review:
            return "Review"
        }
    }
}

enum ImportAccountFilter: String, CaseIterable, Identifiable {
    case all
    case needsAttention
    case newAccounts
    case archivedAccounts
    case existingMatches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All accounts"
        case .needsAttention:
            return "Needs attention"
        case .newAccounts:
            return "New accounts"
        case .archivedAccounts:
            return "Archived accounts"
        case .existingMatches:
            return "Existing matches"
        }
    }
}

enum ImportCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case needsAttention
    case newCategories
    case unused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All categories"
        case .needsAttention:
            return "Needs attention"
        case .newCategories:
            return "New categories"
        case .unused:
            return "Unused"
        }
    }
}

enum ImportTransactionReviewFilter: String, CaseIterable, Identifiable {
    case exceptions
    case all
    case duplicates
    case skipped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exceptions:
            return "Exceptions first"
        case .all:
            return "All rows"
        case .duplicates:
            return "Duplicates"
        case .skipped:
            return "Skipped"
        }
    }
}

struct ImportColumnMappingRule: Codable, Equatable {
    let signature: String
    let mappings: [String: String]
    let unmappedFields: [String]

    init(
        signature: String,
        mappings: [String: String],
        unmappedFields: [String] = []
    ) {
        self.signature = signature
        self.mappings = mappings
        self.unmappedFields = unmappedFields
    }

    private enum CodingKeys: String, CodingKey {
        case signature
        case mappings
        case unmappedFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signature = try container.decode(String.self, forKey: .signature)
        mappings = try container.decode([String: String].self, forKey: .mappings)
        unmappedFields = try container.decodeIfPresent([String].self, forKey: .unmappedFields) ?? []
    }
}

struct ImportAccountRule: Codable, Equatable {
    let key: String
    var type: AccountType?
    var currency: LedgerCurrency?
    var isArchived: Bool?
}

struct ImportStoredRules: Codable, Equatable {
    let version: Int
    var columnMappings: [ImportColumnMappingRule]
    var accountRules: [ImportAccountRule]

    init(
        version: Int = ImportRuleStore.currentVersion,
        columnMappings: [ImportColumnMappingRule] = [],
        accountRules: [ImportAccountRule] = []
    ) {
        self.version = version
        self.columnMappings = columnMappings
        self.accountRules = accountRules
    }
}

enum ImportRuleStore {
    static let currentVersion = 1
    static let storageKey = "pocketLedger.importRules.v1"

    static func load(from defaults: UserDefaults = .standard) -> ImportStoredRules {
        guard let data = defaults.data(forKey: storageKey) else {
            return ImportStoredRules()
        }
        return decoded(data)
    }

    static func save(_ rules: ImportStoredRules, to defaults: UserDefaults = .standard) {
        guard let data = try? encoded(rules) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func encoded(_ rules: ImportStoredRules) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(rules)
    }

    static func decoded(_ data: Data) -> ImportStoredRules {
        guard let rules = try? JSONDecoder().decode(ImportStoredRules.self, from: data),
              rules.version <= currentVersion else {
            return ImportStoredRules()
        }
        return rules
    }

    static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    static func columnSignature(_ columns: [String]) -> String {
        columns.map(normalized).joined(separator: "|")
    }

    static func applying(
        remembered rules: ImportStoredRules,
        to suggested: [ImportField: String?],
        columns: [String]
    ) -> [ImportField: String?] {
        var mapping = suggested
        let signature = columnSignature(columns)
        guard let rule = rules.columnMappings.first(where: { $0.signature == signature }) else {
            return mapping
        }

        for (rawField, column) in rule.mappings {
            guard let field = ImportField(rawValue: rawField), columns.contains(column) else { continue }
            mapping[field] = column
        }
        for rawField in rule.unmappedFields {
            guard let field = ImportField(rawValue: rawField) else { continue }
            mapping[field] = nil
        }
        return mapping
    }

    static func accountRule(
        for name: String,
        in rules: ImportStoredRules
    ) -> ImportAccountRule? {
        let key = ImportAccountCandidate.key(for: name)
        return rules.accountRules.first(where: { $0.key == key })
    }

    static func accountSuggestion(
        for name: String,
        in rules: ImportStoredRules
    ) -> ImportAccountSuggestion? {
        guard let rule = accountRule(for: name, in: rules) else { return nil }
        guard rule.type != nil || rule.currency != nil else { return nil }
        return ImportAccountSuggestion(type: rule.type, currency: rule.currency)
    }

    static func remembering(
        mapping: [ImportField: String?],
        explicitFields: Set<ImportField>? = nil,
        columns: [String],
        accountRules: [ImportAccountRule],
        in rules: ImportStoredRules
    ) -> ImportStoredRules {
        let signature = columnSignature(columns)
        let storedMapping = ImportColumnMappingRule(
            signature: signature,
            mappings: mapping.reduce(into: [String: String]()) { result, pair in
                if let column = pair.value,
                   columns.contains(column),
                   explicitFields == nil || explicitFields?.contains(pair.key) == true {
                    result[pair.key.rawValue] = column
                }
            },
            unmappedFields: (explicitFields ?? Set(ImportField.allCases)).compactMap { field in
                guard (mapping[field] ?? nil) == nil else {
                    return nil
                }
                return field.rawValue
            }.sorted()
        )

        var updated = ImportStoredRules(
            columnMappings: rules.columnMappings,
            accountRules: rules.accountRules
        )
        if explicitFields == nil
            || !storedMapping.mappings.isEmpty
            || !storedMapping.unmappedFields.isEmpty {
            updated.columnMappings.removeAll { $0.signature == signature }
            updated.columnMappings.append(storedMapping)
        }

        for rule in accountRules {
            updated.accountRules.removeAll { $0.key == rule.key }
            updated.accountRules.append(rule)
        }
        updated.accountRules.sort { $0.key < $1.key }
        return updated
    }
}

enum ImportAccountBulkMutation: Equatable {
    case setType(AccountType)
    case setCurrency(LedgerCurrency)
    case setIncludeInTotals(Bool)
    case setArchived(Bool)
    case mapToExisting(UUID)
}

enum ImportCategoryBulkMutation: Equatable {
    case mapToExisting(UUID)
    case setParent(UUID?)
    case excludeUnused
}

enum ImportBulkMutationError: LocalizedError, Equatable {
    case noSelection
    case targetNotFound
    case mixedCurrencies
    case incompatibleCurrency
    case targetIsSelected
    case categoryIsUsed
    case invalidParent

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return "Select at least one row first."
        case .targetNotFound:
            return "The selected target could not be found."
        case .mixedCurrencies:
            return "Accounts with different currencies cannot be mapped to one target."
        case .incompatibleCurrency:
            return "The target account must use the same currency as the selected accounts."
        case .targetIsSelected:
            return "The target cannot be one of the selected rows."
        case .categoryIsUsed:
            return "Only unused provisional categories can be excluded."
        case .invalidParent:
            return "A category cannot be its own parent or a child of one of the selected categories."
        }
    }
}

struct ImportBulkChangeSummary: Equatable {
    let accountCount: Int
    let categoryCount: Int
    let transactionCount: Int
    let movementCount: Int
}

struct ImportFinalSummary: Equatable {
    let activeAccountCount: Int
    let archivedAccountCount: Int
    let categoryCount: Int
    let remappedAccountCount: Int
    let remappedTransactionCount: Int
    let skippedRowCount: Int
    let transactionCount: Int
}

struct ImportDraft {
    let id = UUID()
    let document: ImportedDocument
    let rememberedRules: ImportStoredRules
    var selectedTableID: String
    var mapping: [ImportField: String?]
    var defaultKind: TransactionKind = .expense
    var defaultCurrency: LedgerCurrency = .usd
    var defaultAccountID: UUID?
    var defaultDestinationAccountID: UUID?
    var createMissingAccounts = true
    var createMissingCategories = true
    var step: ImportStep = .source
    var result: FinanceImportResult?
    var importedData: FinanceData?
    var duplicateTransactionIDs: Set<UUID> = []
    var excludedDuplicateIDs: Set<UUID> = []
    var selectedAccountIDs: Set<UUID> = []
    var selectedCategoryIDs: Set<UUID> = []
    var remappedAccountCount = 0
    var remappedTransactionCount = 0
    var explicitMappingFields: Set<ImportField> = []
    var explicitAccountRuleKeys: Set<String> = []
    var explicitTypeCurrencyRuleKeys: Set<String> = []
    var explicitArchiveRuleKeys: Set<String> = []

    init(document: ImportedDocument, existing: FinanceData, rememberedRules: ImportStoredRules) {
        self.document = document
        self.rememberedRules = rememberedRules
        let table = document.preferredTable ?? ImportedTable(id: "empty", name: "Imported rows", columns: [], rows: [])
        selectedTableID = table.id
        mapping = ImportRuleStore.applying(
            remembered: rememberedRules,
            to: FinanceImportParser.suggestedMapping(columns: table.columns),
            columns: table.columns
        )
        defaultAccountID = existing.accounts.first(where: { !$0.isArchived })?.id
        let activeAccounts = existing.accounts.filter { !$0.isArchived }
        defaultDestinationAccountID = activeAccounts.dropFirst().first?.id
            ?? activeAccounts.first?.id
    }

    var selectedTable: ImportedTable {
        document.tables.first(where: { $0.id == selectedTableID })
            ?? document.preferredTable
            ?? ImportedTable(id: "empty", name: "Imported rows", columns: [], rows: [])
    }

    var requiredFieldsAreMapped: Bool {
        ImportField.required.allSatisfy { mapping[$0] ?? nil != nil }
    }

    var preparedData: FinanceData? {
        guard var data = importedData else { return nil }
        data.transactions.removeAll { excludedDuplicateIDs.contains($0.id) }
        return FinanceImportReview.removingUnusedCreatedRecords(from: data)
    }

    var finalSummary: ImportFinalSummary? {
        guard let prepared = preparedData else { return nil }
        return ImportFinalSummary(
            activeAccountCount: prepared.accounts.filter { !$0.isArchived }.count,
            archivedAccountCount: prepared.accounts.filter(\.isArchived).count,
            categoryCount: prepared.categories.count,
            remappedAccountCount: remappedAccountCount,
            remappedTransactionCount: remappedTransactionCount,
            skippedRowCount: (result?.skippedRows ?? 0) + excludedDuplicateIDs.count,
            transactionCount: prepared.transactions.count
        )
    }

    var creationPolicyError: String? {
        guard let summary = finalSummary else { return "No staged data is ready." }
        if !createMissingAccounts, summary.activeAccountCount > 0 {
            return "Creating new active accounts is disabled. Archive or map them before importing."
        }
        if !createMissingCategories, summary.categoryCount > 0 {
            return "Creating new categories is disabled. Map or remove the provisional categories before importing."
        }
        return nil
    }

    mutating func discard() {
        discardPreparedResults()
        step = .source
    }

    mutating func discardPreparedResults() {
        result = nil
        importedData = nil
        duplicateTransactionIDs.removeAll()
        excludedDuplicateIDs.removeAll()
        selectedAccountIDs.removeAll()
        selectedCategoryIDs.removeAll()
        remappedAccountCount = 0
        remappedTransactionCount = 0
    }

    mutating func selectTable(_ tableID: String) {
        selectedTableID = tableID
        explicitMappingFields.removeAll()
        let table = document.tables.first(where: { $0.id == tableID }) ?? selectedTable
        mapping = ImportRuleStore.applying(
            remembered: rememberedRules,
            to: FinanceImportParser.suggestedMapping(columns: table.columns),
            columns: table.columns
        )
    }

    mutating func setMapping(_ field: ImportField, to column: String?) {
        mapping[field] = column
        explicitMappingFields.insert(field)
    }

    mutating func markAccountDecision(
        _ account: Account,
        typeOrCurrency: Bool = true,
        archive: Bool = false
    ) {
        let key = ImportAccountCandidate.key(for: account.name)
        if typeOrCurrency || archive {
            explicitAccountRuleKeys.insert(key)
        }
        if typeOrCurrency {
            explicitTypeCurrencyRuleKeys.insert(key)
        }
        if archive {
            explicitArchiveRuleKeys.insert(key)
        }
    }

    mutating func apply(
        _ mutation: ImportAccountBulkMutation,
        existingAccounts: [Account]
    ) throws -> ImportBulkChangeSummary {
        guard var data = importedData else { throw ImportBulkMutationError.noSelection }
        let selected = data.accounts.filter { selectedAccountIDs.contains($0.id) }
        guard !selected.isEmpty else { throw ImportBulkMutationError.noSelection }

        let affectedTransactionCount = data.transactions.reduce(into: 0) { count, transaction in
            if transaction.outflows.contains(where: { selectedAccountIDs.contains($0.accountID) })
                || transaction.inflows.contains(where: { selectedAccountIDs.contains($0.accountID) }) {
                count += 1
            }
        }
        let affectedMovementCount = data.transactions.reduce(into: 0) { count, transaction in
            count += transaction.outflows.filter { selectedAccountIDs.contains($0.accountID) }.count
            count += transaction.inflows.filter { selectedAccountIDs.contains($0.accountID) }.count
        }

        switch mutation {
        case let .setType(type):
            data.accounts.indices.forEach { index in
                if selectedAccountIDs.contains(data.accounts[index].id) {
                    data.accounts[index].type = type
                }
            }
            selected.forEach { account in
                let key = ImportAccountCandidate.key(for: account.name)
                explicitAccountRuleKeys.insert(key)
                explicitTypeCurrencyRuleKeys.insert(key)
            }
        case let .setCurrency(currency):
            for account in selected where account.currency != currency {
                data = FinanceAccountCurrencyMigration.migrating(
                    data,
                    accountID: account.id,
                    from: account.currency,
                    to: currency
                )
            }
            selected.forEach { account in
                let key = ImportAccountCandidate.key(for: account.name)
                explicitAccountRuleKeys.insert(key)
                explicitTypeCurrencyRuleKeys.insert(key)
            }
        case let .setIncludeInTotals(include):
            data.accounts.indices.forEach { index in
                if selectedAccountIDs.contains(data.accounts[index].id) {
                    data.accounts[index].includeInTotals = include
                }
            }
        case let .setArchived(archived):
            data.accounts.indices.forEach { index in
                if selectedAccountIDs.contains(data.accounts[index].id) {
                    data.accounts[index].isArchived = archived
                }
            }
            selected.forEach { account in
                let key = ImportAccountCandidate.key(for: account.name)
                explicitAccountRuleKeys.insert(key)
                explicitArchiveRuleKeys.insert(key)
            }
        case let .mapToExisting(targetID):
            guard let target = existingAccounts.first(where: { $0.id == targetID }) else {
                throw ImportBulkMutationError.targetNotFound
            }
            let currencies = Set(selected.map(\.currency))
            guard currencies.count == 1 else { throw ImportBulkMutationError.mixedCurrencies }
            guard currencies.first == target.currency else { throw ImportBulkMutationError.incompatibleCurrency }
            guard !selectedAccountIDs.contains(targetID) else { throw ImportBulkMutationError.targetIsSelected }

            for index in data.transactions.indices {
                var transaction = data.transactions[index]
                var changed = false
                transaction.outflows = transaction.outflows.map { movement in
                    guard selectedAccountIDs.contains(movement.accountID) else { return movement }
                    changed = true
                    return MoneyMovement(
                        id: movement.id,
                        accountID: target.id,
                        money: movement.money.recast(to: target.currency)
                    )
                }
                transaction.inflows = transaction.inflows.map { movement in
                    guard selectedAccountIDs.contains(movement.accountID) else { return movement }
                    changed = true
                    return MoneyMovement(
                        id: movement.id,
                        accountID: target.id,
                        money: movement.money.recast(to: target.currency)
                    )
                }
                if changed {
                    data.transactions[index] = transaction
                }
            }
            data.accounts.removeAll { selectedAccountIDs.contains($0.id) }
            remappedAccountCount += selected.count
        }

        importedData = data
        if case .mapToExisting = mutation {
            remappedTransactionCount += affectedTransactionCount
        }
        return ImportBulkChangeSummary(
            accountCount: selected.count,
            categoryCount: 0,
            transactionCount: affectedTransactionCount,
            movementCount: affectedMovementCount
        )
    }

    mutating func apply(
        _ mutation: ImportCategoryBulkMutation,
        existingCategories: [LedgerCategory]
    ) throws -> ImportBulkChangeSummary {
        guard var data = importedData else { throw ImportBulkMutationError.noSelection }
        let selected = data.categories.filter { selectedCategoryIDs.contains($0.id) }
        guard !selected.isEmpty else { throw ImportBulkMutationError.noSelection }

        switch mutation {
        case let .mapToExisting(targetID):
            guard let target = existingCategories.first(where: { $0.id == targetID }) else {
                throw ImportBulkMutationError.targetNotFound
            }
            guard !selectedCategoryIDs.contains(target.id) else {
                throw ImportBulkMutationError.targetIsSelected
            }
            var transactionCount = 0
            for index in data.transactions.indices {
                guard let categoryID = data.transactions[index].categoryID,
                      selectedCategoryIDs.contains(categoryID) else { continue }
                data.transactions[index].categoryID = target.id
                transactionCount += 1
            }
            for index in data.categories.indices where selectedCategoryIDs.contains(data.categories[index].parentID ?? UUID()) {
                data.categories[index].parentID = target.id
            }
            data.categories.removeAll { selectedCategoryIDs.contains($0.id) }
            importedData = data
            return ImportBulkChangeSummary(
                accountCount: 0,
                categoryCount: selected.count,
                transactionCount: transactionCount,
                movementCount: 0
            )
        case let .setParent(parentID):
            if let parentID,
               selectedCategoryIDs.contains(parentID)
                || data.categories.contains(where: { $0.id == parentID && selectedCategoryIDs.contains($0.parentID ?? UUID()) }) {
                throw ImportBulkMutationError.invalidParent
            }
            guard parentID == nil || existingCategories.contains(where: { $0.id == parentID }) || data.categories.contains(where: { $0.id == parentID }) else {
                throw ImportBulkMutationError.targetNotFound
            }
            data.categories.indices.forEach { index in
                if selectedCategoryIDs.contains(data.categories[index].id) {
                    data.categories[index].parentID = parentID
                }
            }
            importedData = data
            return ImportBulkChangeSummary(
                accountCount: 0,
                categoryCount: selected.count,
                transactionCount: 0,
                movementCount: 0
            )
        case .excludeUnused:
            let usedIDs = Set(data.transactions.compactMap(\.categoryID))
            guard selected.allSatisfy({ !usedIDs.contains($0.id) }) else {
                throw ImportBulkMutationError.categoryIsUsed
            }
            for index in data.categories.indices where selectedCategoryIDs.contains(data.categories[index].parentID ?? UUID()) {
                data.categories[index].parentID = selected.first?.parentID
            }
            data.categories.removeAll { selectedCategoryIDs.contains($0.id) }
            importedData = data
            return ImportBulkChangeSummary(
                accountCount: 0,
                categoryCount: selected.count,
                transactionCount: 0,
                movementCount: 0
            )
        }
    }
}

extension ImportField {
    static var required: [ImportField] { [.date, .amount] }
}
