import Foundation
import SwiftUI

enum ImportWizardSheet: Identifiable {
    case account(UUID)
    case accountBulk(ImportWizardAccountBulkKind)
    case categoryBulk(ImportWizardCategoryBulkKind)

    var id: String {
        switch self {
        case let .account(id):
            return "account-\(id.uuidString)"
        case let .accountBulk(kind):
            return "account-bulk-\(kind.rawValue)"
        case let .categoryBulk(kind):
            return "category-bulk-\(kind.rawValue)"
        }
    }
}

enum ImportWizardAccountBulkKind: String, Identifiable {
    case type
    case currency
    case totals
    case archive
    case mapToExisting

    var id: String { rawValue }
}

enum ImportWizardCategoryBulkKind: String, Identifiable {
    case mapToExisting
    case parent
    case excludeUnused

    var id: String { rawValue }
}

private func affectedTransactionCount(for accounts: [Account], in data: FinanceData?) -> Int {
    let ids = Set(accounts.map(\.id))
    return data?.transactions.filter { transaction in
        transaction.outflows.contains { ids.contains($0.accountID) }
            || transaction.inflows.contains { ids.contains($0.accountID) }
    }.count ?? 0
}

private func affectedMovementCount(for accounts: [Account], in data: FinanceData?) -> Int {
    let ids = Set(accounts.map(\.id))
    return data?.transactions.reduce(into: 0) { count, transaction in
        count += transaction.outflows.filter { ids.contains($0.accountID) }.count
        count += transaction.inflows.filter { ids.contains($0.accountID) }.count
    } ?? 0
}

private func affectedTransactionCount(for categories: [LedgerCategory], in data: FinanceData?) -> Int {
    let ids = Set(categories.map(\.id))
    return data?.transactions.filter { transaction in
        guard let categoryID = transaction.categoryID else { return false }
        return ids.contains(categoryID)
    }.count ?? 0
}

struct ImportPreparationInputs: Equatable {
    let draftID: UUID
    let tableID: String
    let mapping: [ImportField: String?]
    let defaultKind: TransactionKind
    let defaultCurrency: LedgerCurrency
    let defaultAccountID: UUID?
    let defaultDestinationAccountID: UUID?
    let createMissingAccounts: Bool
    let createMissingCategories: Bool
    let ledgerRevision: Int

    init(draft: ImportDraft, ledgerRevision: Int) {
        draftID = draft.id
        tableID = draft.selectedTableID
        mapping = draft.mapping
        defaultKind = draft.defaultKind
        defaultCurrency = draft.defaultCurrency
        defaultAccountID = draft.defaultAccountID
        defaultDestinationAccountID = draft.defaultDestinationAccountID
        createMissingAccounts = draft.createMissingAccounts
        createMissingCategories = draft.createMissingCategories
        self.ledgerRevision = ledgerRevision
    }

    func matches(_ draft: ImportDraft, ledgerRevision: Int) -> Bool {
        self == ImportPreparationInputs(draft: draft, ledgerRevision: ledgerRevision)
    }
}

private struct ImportBuildInput: @unchecked Sendable {
    let table: ImportedTable
    let mapping: [ImportField: String?]
    let options: ImportOptions
    let existing: FinanceData
    let rememberedRules: ImportStoredRules
}

private struct ImportCandidateInput: @unchecked Sendable {
    let table: ImportedTable
    let mapping: [ImportField: String?]
}

private struct ImportCandidateOutput: @unchecked Sendable {
    let candidates: [ImportAccountCandidate]
}

private struct ImportBuildOutput: @unchecked Sendable {
    let result: Result<FinanceImportResult, Error>
}

private struct DuplicateCheckOutput: @unchecked Sendable {
    let ids: Set<UUID>
}

private struct DuplicateCheckInput: @unchecked Sendable {
    let importedData: FinanceData
    let existingData: FinanceData
}

private func applyRememberedAccountRules(to data: inout FinanceData, rules: ImportStoredRules) {
    for index in data.accounts.indices {
        guard let rule = ImportRuleStore.accountRule(for: data.accounts[index].name, in: rules) else {
            continue
        }
        if let type = rule.type {
            data.accounts[index].type = type
        }
        if let currency = rule.currency, currency != data.accounts[index].currency {
            data = FinanceAccountCurrencyMigration.migrating(
                data,
                accountID: data.accounts[index].id,
                from: data.accounts[index].currency,
                to: currency,
                preserveMovementCurrencies: true
            )
        }
        if let isArchived = rule.isArchived,
           let accountIndex = data.accounts.firstIndex(where: { $0.id == data.accounts[index].id }) {
            data.accounts[accountIndex].isArchived = isArchived
        }
    }
}

@MainActor
struct ImportWizardView: View {
    @ObservedObject var store: LedgerStore
    let document: ImportedDocument

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ImportDraft
    @State private var presentedSheet: ImportWizardSheet?
    @State private var isPreparing = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var candidateTask: Task<ImportCandidateOutput, Never>?
    @State private var importBuildTask: Task<ImportBuildOutput, Never>?
    @State private var duplicateCheckTask: Task<DuplicateCheckOutput, Never>?
    @State private var preparationToken = UUID()
    @State private var isShowingFinalConfirmation = false
    @State private var errorMessage: String?
    @State private var rememberRules = false

    init(store: LedgerStore, document: ImportedDocument) {
        _store = ObservedObject(wrappedValue: store)
        self.document = document
        _draft = State(
            initialValue: ImportDraft(
                document: document,
                existing: store.data,
                rememberedRules: ImportRuleStore.load()
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ImportWizardProgressView(step: draft.step)
                Divider()
                stepContent
            }
            .navigationTitle(draft.step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        cancelPreparation()
                        draft.discard()
                        dismiss()
                    }
                    if draft.step != .source {
                        Button("Back") {
                            goBack()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft.step == .review {
                        Button("Import \(preparedTransactionCount)") {
                            isShowingFinalConfirmation = true
                        }
                        .disabled(!canImport)
                        .accessibilityIdentifier("importWizard.import")
                    } else if isPreparing {
                        ProgressView()
                    } else {
                        Button("Next") {
                            advance()
                        }
                        .disabled(!canAdvance)
                        .accessibilityIdentifier("importWizard.next")
                    }
                }
            }
            .alert(
                "Import issue",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "Import this staged data?",
                isPresented: $isShowingFinalConfirmation,
                titleVisibility: .visible
            ) {
                Button("Import") {
                    importDraft()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(finalSummaryText)
            }
        }
        .accessibilityIdentifier("importWizard")
        .onDisappear(perform: cancelPreparation)
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                sheetContent(for: sheet)
            }
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch draft.step {
        case .source:
            ImportWizardSourceStep(draft: $draft)
        case .defaults:
            ImportWizardDefaultsStep(draft: $draft, accounts: store.data.accounts)
        case .organize:
            ImportWizardOrganizeStep(
                draft: $draft,
                store: store,
                presentedSheet: $presentedSheet,
                errorMessage: $errorMessage
            )
        case .review:
            ImportWizardReviewStep(
                draft: $draft,
                store: store,
                rememberRules: $rememberRules
            )
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: ImportWizardSheet) -> some View {
        switch sheet {
        case let .account(accountID):
            if let account = draft.importedData?.accounts.first(where: { $0.id == accountID }) {
                ImportWizardAccountEditor(account: account) { updated in
                    updateImportedAccount(updated)
                    presentedSheet = nil
                }
            } else {
                Text("This account is no longer in the staged import.")
                    .padding()
            }
        case let .accountBulk(kind):
            ImportWizardBulkAccountsSheet(
                kind: kind,
                selectedAccounts: selectedImportedAccounts,
                existingAccounts: store.data.accounts,
                affectedTransactionCount: affectedTransactionCount(
                    for: selectedImportedAccounts,
                    in: draft.importedData
                ),
                affectedMovementCount: affectedMovementCount(
                    for: selectedImportedAccounts,
                    in: draft.importedData
                ),
                onApply: { mutation in
                    do {
                        _ = try draft.apply(mutation, existingAccounts: store.data.accounts)
                        draft.selectedAccountIDs.removeAll()
                        presentedSheet = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            )
        case let .categoryBulk(kind):
            ImportWizardBulkCategoriesSheet(
                kind: kind,
                selectedCategories: selectedImportedCategories,
                existingCategories: store.data.categories,
                importedCategories: draft.importedData?.categories ?? [],
                affectedTransactionCount: affectedTransactionCount(
                    for: selectedImportedCategories,
                    in: draft.importedData
                ),
                onApply: { mutation in
                    do {
                        _ = try draft.apply(mutation, existingCategories: store.data.categories)
                        draft.selectedCategoryIDs.removeAll()
                        presentedSheet = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            )
        }
    }

    private var previousStep: ImportStep {
        ImportStep(rawValue: max(ImportStep.source.rawValue, draft.step.rawValue - 1)) ?? .source
    }

    private var canAdvance: Bool {
        switch draft.step {
        case .source:
            return draft.requiredFieldsAreMapped
        case .defaults, .organize:
            return !isPreparing
        case .review:
            return false
        }
    }

    private var canImport: Bool {
        guard let preparedData = draft.preparedData else { return false }
        return !preparedData.transactions.isEmpty
            || !preparedData.accounts.isEmpty
            || !preparedData.categories.isEmpty
    }

    private var preparedTransactionCount: Int {
        draft.preparedData?.transactions.count ?? 0
    }

    private var selectedImportedAccounts: [Account] {
        draft.importedData?.accounts.filter { draft.selectedAccountIDs.contains($0.id) } ?? []
    }

    private var selectedImportedCategories: [LedgerCategory] {
        draft.importedData?.categories.filter { draft.selectedCategoryIDs.contains($0.id) } ?? []
    }

    private var finalSummaryText: String {
        guard let summary = draft.finalSummary else { return "No staged data is ready." }
        return "Create \(summary.activeAccountCount) active accounts, \(summary.archivedAccountCount) archived accounts, and \(summary.categoryCount) categories. Remap \(summary.remappedAccountCount) accounts across \(summary.remappedTransactionCount) transactions. Skip \(summary.skippedRowCount) rows and import \(summary.transactionCount) transactions."
    }

    private func advance() {
        switch draft.step {
        case .source:
            draft.step = .defaults
        case .defaults:
            prepareImport()
        case .organize:
            draft.step = .review
        case .review:
            break
        }
    }

    private func prepareImport() {
        guard !isPreparing else { return }
        isPreparing = true
        let table = draft.selectedTable
        let mapping = draft.mapping
        let currentDraft = draft
        let inputs = ImportPreparationInputs(draft: draft, ledgerRevision: store.ledgerRevision)
        preparationToken = UUID()
        let token = preparationToken

        preparationTask = Task { @MainActor in
            defer {
                if preparationToken == token {
                    isPreparing = false
                    preparationTask = nil
                }
            }
            let candidateInput = ImportCandidateInput(table: table, mapping: mapping)
            candidateTask = Task.detached(priority: .userInitiated) {
                ImportCandidateOutput(candidates: FinanceImportBuilder.accountImportCandidates(
                    table: candidateInput.table,
                    mapping: candidateInput.mapping
                ))
            }
            guard let candidateTask else { return }
            let candidates = await candidateTask.value.candidates
            self.candidateTask = nil
            guard !Task.isCancelled, preparationToken == token else { return }
            guard inputs.matches(draft, ledgerRevision: store.ledgerRevision) else {
                discardStalePreparation()
                return
            }
            let accountMapping: FoundationModelService.AccountMappingResult
            if ProcessInfo.processInfo.arguments.contains("-ImportWizardUITest") {
                accountMapping = FoundationModelService.AccountMappingResult(suggestions: [:], warning: nil)
            } else {
                accountMapping = await FoundationModelService.classifyImportAccounts(candidates)
            }
            guard !Task.isCancelled, preparationToken == token else { return }
            guard inputs.matches(draft, ledgerRevision: store.ledgerRevision) else {
                discardStalePreparation()
                return
            }

            var suggestions = accountMapping.suggestions
            for candidate in candidates {
                if let remembered = ImportRuleStore.accountSuggestion(
                    for: candidate.name,
                    in: currentDraft.rememberedRules
                ) {
                    suggestions[ImportAccountCandidate.key(for: candidate.name)] = remembered
                }
            }

            let options = ImportOptions(
                defaultKind: currentDraft.defaultKind,
                defaultCurrency: currentDraft.defaultCurrency,
                defaultAccountID: currentDraft.defaultAccountID,
                defaultDestinationAccountID: currentDraft.defaultDestinationAccountID,
                createMissingAccounts: true,
                createMissingCategories: true,
                accountSuggestions: suggestions
            )

            let buildInput = ImportBuildInput(
                table: table,
                mapping: mapping,
                options: options,
                existing: store.data,
                rememberedRules: currentDraft.rememberedRules
            )
            importBuildTask = Task.detached(priority: .userInitiated) {
                do {
                    var built = try FinanceImportBuilder.build(
                        table: buildInput.table,
                        mapping: buildInput.mapping,
                        options: buildInput.options,
                        existing: buildInput.existing
                    )
                    var importedData = built.data
                    applyRememberedAccountRules(to: &importedData, rules: buildInput.rememberedRules)
                    built = FinanceImportResult(
                        data: importedData,
                        importedRows: built.importedRows,
                        skippedRows: built.skippedRows,
                        warnings: built.warnings
                    )
                    return ImportBuildOutput(result: .success(built))
                } catch {
                    return ImportBuildOutput(result: .failure(error))
                }
            }
            guard let importBuildTask else { return }
            let buildOutput = await importBuildTask.value
            self.importBuildTask = nil
            guard !Task.isCancelled, preparationToken == token else { return }
            guard inputs.matches(draft, ledgerRevision: store.ledgerRevision) else {
                discardStalePreparation()
                return
            }

            do {
                let built = try buildOutput.result.get()
                var importedData = built.data
                var warnings = built.warnings
                if let warning = accountMapping.warning {
                    warnings.insert(warning, at: 0)
                }
                let result = FinanceImportResult(
                    data: importedData,
                    importedRows: built.importedRows,
                    skippedRows: built.skippedRows,
                    warnings: warnings
                )
                draft.result = result
                draft.importedData = importedData
                let duplicateInput = DuplicateCheckInput(
                    importedData: importedData,
                    existingData: store.data
                )
                duplicateCheckTask = Task.detached(priority: .userInitiated) {
                    DuplicateCheckOutput(ids: FinanceImportReview.duplicateTransactionIDs(
                        in: duplicateInput.importedData,
                        existing: duplicateInput.existingData
                    ))
                }
                guard let duplicateCheckTask else { return }
                let duplicateOutput = await duplicateCheckTask.value
                self.duplicateCheckTask = nil
                guard !Task.isCancelled, preparationToken == token else { return }
                guard inputs.matches(draft, ledgerRevision: store.ledgerRevision) else {
                    discardStalePreparation()
                    return
                }
                draft.duplicateTransactionIDs = duplicateOutput.ids
                draft.step = .organize
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func goBack() {
        cancelPreparation()
        if draft.step == .organize {
            draft.discardPreparedResults()
        }
        draft.step = previousStep
    }

    private func cancelPreparation() {
        preparationToken = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        candidateTask?.cancel()
        candidateTask = nil
        importBuildTask?.cancel()
        importBuildTask = nil
        duplicateCheckTask?.cancel()
        duplicateCheckTask = nil
        isPreparing = false
    }

    private func discardStalePreparation() {
        draft.discardPreparedResults()
        errorMessage = "Import settings or ledger data changed. Tap Next to prepare again."
    }

    private func updateImportedAccount(_ updated: Account) {
        guard var data = draft.importedData,
              let old = data.accounts.first(where: { $0.id == updated.id }) else { return }
        if old.currency != updated.currency {
            data = FinanceAccountCurrencyMigration.migrating(
                data,
                accountID: updated.id,
                from: old.currency,
                to: updated.currency
            )
        }
        guard let index = data.accounts.firstIndex(where: { $0.id == updated.id }) else { return }
        data.accounts[index].name = updated.name
        data.accounts[index].type = updated.type
        data.accounts[index].includeInTotals = updated.includeInTotals
        data.accounts[index].isArchived = updated.isArchived
        draft.importedData = data
        draft.markAccountDecision(
            updated,
            typeOrCurrency: old.type != updated.type || old.currency != updated.currency,
            archive: old.isArchived != updated.isArchived
        )
    }

    private func importDraft() {
        guard let prepared = draft.preparedData else { return }
        if let creationPolicyError = draft.creationPolicyError {
            errorMessage = creationPolicyError
            return
        }
        guard store.mergeData(prepared) else {
            errorMessage = store.lastActionStatus ?? "The import could not be saved."
            return
        }
        if rememberRules {
            ImportRuleStore.save(rememberedRulesForCurrentDraft())
        }
        dismiss()
    }

    private func rememberedRulesForCurrentDraft() -> ImportStoredRules {
        let accounts = draft.importedData?.accounts ?? []
        let rules = accounts.compactMap { account -> ImportAccountRule? in
            let key = ImportAccountCandidate.key(for: account.name)
            guard draft.explicitAccountRuleKeys.contains(key) else { return nil }
            return ImportAccountRule(
                key: key,
                type: draft.explicitTypeCurrencyRuleKeys.contains(key) ? account.type : nil,
                currency: draft.explicitTypeCurrencyRuleKeys.contains(key) ? account.currency : nil,
                isArchived: draft.explicitArchiveRuleKeys.contains(key) ? account.isArchived : nil
            )
        }
        return ImportRuleStore.remembering(
            mapping: draft.mapping,
            explicitFields: draft.explicitMappingFields,
            columns: draft.selectedTable.columns,
            accountRules: rules,
            in: draft.rememberedRules
        )
    }

}

private struct ImportWizardProgressView: View {
    let step: ImportStep

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ImportStep.allCases) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.rawValue <= step.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary)
                        Text(item.shortTitle)
                            .font(.subheadline.weight(item == step ? .semibold : .regular))
                    }
                    .foregroundStyle(item == step ? .primary : .secondary)
                    if item != ImportStep.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("importWizard.steps")
    }
}

private struct ImportWizardSourceStep: View {
    @Binding var draft: ImportDraft
    @State private var isRecommendedExpanded = false
    @State private var isReportingExpanded = false
    @State private var isAdvancedExpanded = false
    @State private var areSamplesExpanded = false

    private let requiredFields: [ImportField] = [.date, .amount]
    private let recommendedFields: [ImportField] = [.kind, .currency, .account, .category, .note]
    private let reportingFields: [ImportField] = [.baseAmount, .baseCurrency]
    private let advancedFields: [ImportField] = [
        .accountType,
        .destinationAccount,
        .destinationAccountType,
        .destinationAmount,
        .destinationCurrency
    ]

    var body: some View {
        Form {
            Section("Source") {
                LabeledContent("File", value: draft.document.fileName)
                LabeledContent("Format", value: draft.document.format.displayName)
                if draft.document.tables.count > 1 {
                    Picker("Table", selection: $draft.selectedTableID) {
                        ForEach(draft.document.tables) { table in
                            Text(table.name).tag(table.id)
                        }
                    }
                    .onChange(of: draft.selectedTableID) { _, tableID in
                        draft.selectTable(tableID)
                    }
                }
                Text("\(draft.selectedTable.rows.count) rows · \(draft.selectedTable.columns.count) columns")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            mappingSection("Required", fields: requiredFields)
            DisclosureGroup("Recommended fields · \(mappedCount(recommendedFields))/\(recommendedFields.count)", isExpanded: $isRecommendedExpanded) {
                mappingRows(recommendedFields)
            }
            DisclosureGroup("Reporting conversion · \(mappedCount(reportingFields))/\(reportingFields.count)", isExpanded: $isReportingExpanded) {
                mappingRows(reportingFields)
            }
            DisclosureGroup("Advanced transfers · \(mappedCount(advancedFields))/\(advancedFields.count)", isExpanded: $isAdvancedExpanded) {
                mappingRows(advancedFields)
            }

            DisclosureGroup("Sample rows", isExpanded: $areSamplesExpanded) {
                Section {
                    ForEach(Array(draft.selectedTable.rows.prefix(3).enumerated()), id: \.offset) { index, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Row \(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(sampleText(for: row))
                                .font(.footnote)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .pocketListSurface()
        .accessibilityIdentifier("importWizard.source")
    }

    @ViewBuilder
    private func mappingSection(_ title: String, fields: [ImportField]) -> some View {
        Section(title) {
            mappingRows(fields)
        }
    }

    @ViewBuilder
    private func mappingRows(_ fields: [ImportField]) -> some View {
        ForEach(fields) { field in
            ImportWizardMappingRow(
                field: field,
                selection: Binding(
                    get: { draft.mapping[field] ?? nil },
                    set: { draft.setMapping(field, to: $0) }
                ),
                columns: draft.selectedTable.columns,
                isRequired: requiredFields.contains(field),
                sampleValue: sampleValue(for: field)
            )
        }
    }

    private func mappedCount(_ fields: [ImportField]) -> Int {
        fields.filter { draft.mapping[$0] != nil }.count
    }

    private func sampleValue(for field: ImportField) -> String? {
        guard let column = draft.mapping[field] ?? nil,
              let columnIndex = draft.selectedTable.columns.firstIndex(of: column) else { return nil }
        for row in draft.selectedTable.rows where row.indices.contains(columnIndex) {
            let value = row[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func sampleText(for row: [String]) -> String {
        zip(draft.selectedTable.columns, row)
            .prefix(4)
            .map { "\($0.0): \($0.1.isEmpty ? "—" : $0.1)" }
            .joined(separator: " · ")
    }
}

private struct ImportWizardMappingRow: View {
    let field: ImportField
    @Binding var selection: String?
    let columns: [String]
    let isRequired: Bool
    let sampleValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(field.displayName, selection: $selection) {
                Text("Not mapped").tag(nil as String?)
                ForEach(columns, id: \.self) { column in
                    Text(column).tag(Optional(column))
                }
            }
            if isRequired, selection == nil {
                Label("Required", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let sampleValue {
                Text("Example: \(sampleValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(field.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ImportWizardDefaultsStep: View {
    @Binding var draft: ImportDraft
    let accounts: [Account]

    private var activeAccounts: [Account] {
        accounts.filter { !$0.isArchived }
    }

    var body: some View {
        Form {
            Section("Fallback values") {
                Picker("Default type", selection: $draft.defaultKind) {
                    ForEach(TransactionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Picker("Default currency", selection: $draft.defaultCurrency) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
            }

            Section("Default accounts") {
                Picker("Source account", selection: $draft.defaultAccountID) {
                    Text("Let each row decide").tag(nil as UUID?)
                    ForEach(activeAccounts) { account in
                        Text("\(account.name) · \(account.currency.rawValue)").tag(Optional(account.id))
                    }
                }
                Picker("Destination account", selection: $draft.defaultDestinationAccountID) {
                    Text("Let each row decide").tag(nil as UUID?)
                    ForEach(activeAccounts) { account in
                        Text("\(account.name) · \(account.currency.rawValue)").tag(Optional(account.id))
                    }
                }
            }

            Section("Creation policy") {
                Toggle("Create missing active accounts", isOn: $draft.createMissingAccounts)
                Toggle("Create missing categories", isOn: $draft.createMissingCategories)
                Text("All discovered rows remain staged for review. Explicitly archived provisional accounts are retained even when active account creation is disabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pocketListSurface()
        .accessibilityIdentifier("importWizard.defaults")
    }
}

@MainActor
private struct ImportWizardOrganizeStep: View {
    @Binding var draft: ImportDraft
    @ObservedObject var store: LedgerStore
    @Binding var presentedSheet: ImportWizardSheet?
    @Binding var errorMessage: String?

    @State private var searchText = ""
    @State private var accountFilter: ImportAccountFilter = .all
    @State private var categoryFilter: ImportCategoryFilter = .all
    @State private var isSelectingAccounts = false
    @State private var isSelectingCategories = false

    var body: some View {
        ZStack {
            if let data = draft.importedData {
                List {
                    Section {
                        HStack {
                            Label("\(data.accounts.count) accounts", systemImage: "person.crop.circle")
                            Spacer()
                            Text("\(data.categories.count) categories")
                                .foregroundStyle(.secondary)
                        }
                        Text("Review provisional records here before any data is written. Tap a row for detailed edits, or select several rows for a bulk action.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    accountsSection(data: data)
                    categoriesSection(data: data)
                }
                .listStyle(.insetGrouped)
                .pocketListSurface()
                .searchable(text: $searchText, prompt: "Search accounts and categories")
            } else {
                ContentUnavailableView("Preparing import", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importWizard.organize")
    }

    @ViewBuilder
    private func accountsSection(data: FinanceData) -> some View {
        Section {
            HStack {
                Picker("Filter", selection: $accountFilter) {
                    ForEach(ImportAccountFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Button(isSelectingAccounts ? "Done" : "Select") {
                    isSelectingAccounts.toggle()
                    if !isSelectingAccounts { draft.selectedAccountIDs.removeAll() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("importWizard.accountSelect")
                if !draft.selectedAccountIDs.isEmpty {
                    Menu {
                        Button("Set account type") { presentedSheet = .accountBulk(.type) }
                        Button("Set currency") { presentedSheet = .accountBulk(.currency) }
                        Button("Include in totals") { presentedSheet = .accountBulk(.totals) }
                        Button("Exclude from totals") {
                            applyAccountMutation(.setIncludeInTotals(false))
                        }
                        Button("Archive") { presentedSheet = .accountBulk(.archive) }
                        Button("Restore") { applyAccountMutation(.setArchived(false)) }
                        Button("Map to existing account") { presentedSheet = .accountBulk(.mapToExisting) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Bulk account actions")
                    .accessibilityIdentifier("importWizard.bulkAccounts")
                }
            }

            if accountFilter == .existingMatches {
                let matches = existingAccountMatches(in: data)
                if matches.isEmpty {
                    Text("No existing account matches were found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { account in
                        ImportWizardExistingMatchRow(
                            account: account,
                            usageCount: usageCount(for: account.id, in: data)
                        )
                    }
                }
            } else if filteredAccounts(from: data).isEmpty {
                Text("No accounts match this filter.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredAccounts(from: data)) { account in
                    accountRow(account, data: data)
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Archived accounts stay in the import even when no transaction currently references them. They will not appear in active account pickers after import.")
        }
    }

    @ViewBuilder
    private func categoriesSection(data: FinanceData) -> some View {
        Section {
            HStack {
                Picker("Filter", selection: $categoryFilter) {
                    ForEach(ImportCategoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Button(isSelectingCategories ? "Done" : "Select") {
                    isSelectingCategories.toggle()
                    if !isSelectingCategories { draft.selectedCategoryIDs.removeAll() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("importWizard.categorySelect")
                if !draft.selectedCategoryIDs.isEmpty {
                    Menu {
                        Button("Map to existing category") {
                            presentedSheet = .categoryBulk(.mapToExisting)
                        }
                        Button("Change parent category") {
                            presentedSheet = .categoryBulk(.parent)
                        }
                        Button("Exclude unused") {
                            presentedSheet = .categoryBulk(.excludeUnused)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Bulk category actions")
                    .accessibilityIdentifier("importWizard.bulkCategories")
                }
            }

            if filteredCategories(from: data).isEmpty {
                Text("No categories match this filter.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredCategories(from: data)) { category in
                    categoryRow(category, data: data)
                }
            }
        } header: {
            Text("Categories")
        }
    }

    private func accountRow(_ account: Account, data: FinanceData) -> some View {
        Button {
            if isSelectingAccounts {
                toggleAccountSelection(account.id)
            } else {
                presentedSheet = .account(account.id)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelectingAccounts {
                    Image(systemName: draft.selectedAccountIDs.contains(account.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(draft.selectedAccountIDs.contains(account.id) ? Color.accentColor : Color.secondary)
                } else {
                    Image(systemName: account.type.systemImage)
                        .foregroundStyle(account.isArchived ? Color.secondary : Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name.isEmpty ? "Unnamed account" : account.name)
                        .foregroundStyle(.primary)
                    Text("\(usageCount(for: account.id, in: data)) uses · \(account.currency.rawValue) · \(account.type.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(accountStatus(for: account))
                        .font(.caption2)
                        .foregroundStyle(account.isArchived ? Color.orange : Color.secondary)
                }
                Spacer()
                if account.isArchived {
                    Text("Archived")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("importWizard.accountRow.\(ImportRuleStore.normalized(account.name))")
    }

    private func categoryRow(_ category: LedgerCategory, data: FinanceData) -> some View {
        Button {
            if isSelectingCategories {
                toggleCategorySelection(category.id)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelectingCategories {
                    Image(systemName: draft.selectedCategoryIDs.contains(category.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(draft.selectedCategoryIDs.contains(category.id) ? Color.accentColor : Color.secondary)
                } else {
                    Image(systemName: category.systemImage)
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(categoryPath(for: category.id, in: data))
                        .foregroundStyle(.primary)
                    Text("\(categoryUsage(for: category.id, in: data)) uses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func filteredAccounts(from data: FinanceData) -> [Account] {
        data.accounts.filter { account in
            let matchesSearch = searchText.isEmpty
                || account.name.localizedCaseInsensitiveContains(searchText)
                || account.type.displayName.localizedCaseInsensitiveContains(searchText)
                || account.currency.rawValue.localizedCaseInsensitiveContains(searchText)
            guard matchesSearch else { return false }
            switch accountFilter {
            case .all:
                return true
            case .needsAttention:
                return accountNeedsAttention(account)
            case .newAccounts:
                return !account.isArchived
            case .archivedAccounts:
                return account.isArchived
            case .existingMatches:
                return false
            }
        }
    }

    private func filteredCategories(from data: FinanceData) -> [LedgerCategory] {
        data.categories.filter { category in
            let matchesSearch = searchText.isEmpty
                || categoryPath(for: category.id, in: data).localizedCaseInsensitiveContains(searchText)
            guard matchesSearch else { return false }
            switch categoryFilter {
            case .all:
                return true
            case .needsAttention:
                return categoryUsage(for: category.id, in: data) == 0
            case .newCategories:
                return !category.isArchived
            case .unused:
                return categoryUsage(for: category.id, in: data) == 0
            }
        }
    }

    private func accountNeedsAttention(_ account: Account) -> Bool {
        account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasExistingMatch(account)
    }

    private func hasExistingMatch(_ account: Account) -> Bool {
        store.data.accounts.contains {
            $0.id != account.id && $0.name.caseInsensitiveCompare(account.name) == .orderedSame
        }
    }

    private func existingAccountMatches(in data: FinanceData) -> [Account] {
        let candidateNames = Set(
            FinanceImportBuilder.accountImportCandidates(
                table: draft.selectedTable,
                mapping: draft.mapping
            ).map { ImportAccountCandidate.key(for: $0.name) }
        )
        return store.data.accounts.filter { account in
            candidateNames.contains(ImportAccountCandidate.key(for: account.name))
                && (searchText.isEmpty || account.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func accountStatus(for account: Account) -> String {
        hasExistingMatch(account) ? "Matches an existing account · tap to edit" : "New provisional account · tap to edit"
    }

    private func usageCount(for accountID: UUID, in data: FinanceData) -> Int {
        data.transactions.reduce(into: 0) { count, transaction in
            count += transaction.outflows.filter { $0.accountID == accountID }.count
            count += transaction.inflows.filter { $0.accountID == accountID }.count
        }
    }

    private func categoryUsage(for categoryID: UUID, in data: FinanceData) -> Int {
        data.transactions.filter { $0.categoryID == categoryID }.count
    }

    private func categoryPath(for categoryID: UUID, in data: FinanceData) -> String {
        var names: [String] = []
        var currentID: UUID? = categoryID
        var visited: Set<UUID> = []
        while let id = currentID,
              visited.insert(id).inserted,
              let category = data.categories.first(where: { $0.id == id }) {
            names.append(category.name)
            currentID = category.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    private func toggleAccountSelection(_ id: UUID) {
        if draft.selectedAccountIDs.contains(id) {
            draft.selectedAccountIDs.remove(id)
        } else {
            draft.selectedAccountIDs.insert(id)
        }
    }

    private func toggleCategorySelection(_ id: UUID) {
        if draft.selectedCategoryIDs.contains(id) {
            draft.selectedCategoryIDs.remove(id)
        } else {
            draft.selectedCategoryIDs.insert(id)
        }
    }

    private func applyAccountMutation(_ mutation: ImportAccountBulkMutation) {
        do {
            _ = try draft.apply(mutation, existingAccounts: store.data.accounts)
            draft.selectedAccountIDs.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private struct ImportWizardExistingMatchRow: View {
    let account: Account
    let usageCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                Text("Existing account · \(usageCount) imported uses · \(account.currency.rawValue) · \(account.type.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if account.isArchived {
                Text("Archived")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ImportWizardAccountEditor: View {
    let account: Account
    let onSave: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var type: AccountType
    @State private var currency: LedgerCurrency
    @State private var includeInTotals: Bool
    @State private var isArchived: Bool

    init(account: Account, onSave: @escaping (Account) -> Void) {
        self.account = account
        self.onSave = onSave
        _name = State(initialValue: account.name)
        _type = State(initialValue: account.type)
        _currency = State(initialValue: account.currency)
        _includeInTotals = State(initialValue: account.includeInTotals)
        _isArchived = State(initialValue: account.isArchived)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                Picker("Currency", selection: $currency) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                Toggle("Include in totals", isOn: $includeInTotals)
                Toggle("Archive account", isOn: $isArchived)
            }
            if currency != account.currency {
                Section {
                    Label("Changing currency recasts the opening balance and every staged movement for this account.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .pocketListSurface()
        .navigationTitle("Edit account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var updated = account
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.type = type
                    updated.currency = currency
                    updated.includeInTotals = includeInTotals
                    updated.isArchived = isArchived
                    onSave(updated)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct ImportWizardBulkAccountsSheet: View {
    let kind: ImportWizardAccountBulkKind
    let selectedAccounts: [Account]
    let existingAccounts: [Account]
    let affectedTransactionCount: Int
    let affectedMovementCount: Int
    let onApply: (ImportAccountBulkMutation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: AccountType = .cash
    @State private var currency: LedgerCurrency = .usd
    @State private var includeInTotals = true
    @State private var isArchived = true
    @State private var targetID: UUID?
    @State private var isConfirmingMap = false

    private var currencies: Set<LedgerCurrency> {
        Set(selectedAccounts.map(\.currency))
    }

    private var compatibleTargets: [Account] {
        guard currencies.count == 1, let currency = currencies.first else { return [] }
        return existingAccounts.filter { account in
            !account.isArchived
                && !selectedAccounts.contains(where: { selected in selected.id == account.id })
                && account.currency == currency
        }
    }

    var body: some View {
        Form {
            Section {
                Text("\(selectedAccounts.count) account rows selected")
                Text("\(affectedMovementCount) staged movements across \(affectedTransactionCount) transactions")
                    .foregroundStyle(.secondary)
            }

            switch kind {
            case .type:
                Picker("Account type", selection: $type) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            case .currency:
                Picker("Currency", selection: $currency) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                Label("Opening balances and staged movements will be recast to the selected currency.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case .totals:
                Picker("Totals", selection: $includeInTotals) {
                    Text("Include in totals").tag(true)
                    Text("Exclude from totals").tag(false)
                }
            case .archive:
                Picker("Archive", selection: $isArchived) {
                    Text("Archive accounts").tag(true)
                    Text("Restore accounts").tag(false)
                }
            case .mapToExisting:
                if currencies.count != 1 {
                    Label("Mixed-currency selections cannot be mapped to one target.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if compatibleTargets.isEmpty {
                    Text("No active existing account uses the selected currency.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Existing account", selection: $targetID) {
                        Text("Choose a target").tag(nil as UUID?)
                        ForEach(compatibleTargets) { account in
                            Text("\(account.name) · \(account.currency.rawValue)").tag(Optional(account.id))
                        }
                    }
                    Text("The selected provisional accounts and their movements will be remapped to the target.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .pocketListSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply() }
                    .disabled(!canApply)
            }
        }
        .confirmationDialog(
            "Confirm account remapping?",
            isPresented: $isConfirmingMap,
            titleVisibility: .visible
        ) {
            Button("Map \(selectedAccounts.count) accounts") {
                if let targetID { onApply(.mapToExisting(targetID)) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes \(affectedMovementCount) staged movements across \(affectedTransactionCount) transactions.")
        }
    }

    private var title: String {
        switch kind {
        case .type:
            return "Set account type"
        case .currency:
            return "Set currency"
        case .totals:
            return "Totals"
        case .archive:
            return "Archive accounts"
        case .mapToExisting:
            return "Map to existing"
        }
    }

    private var canApply: Bool {
        switch kind {
        case .mapToExisting:
            return targetID != nil && currencies.count == 1
        default:
            return !selectedAccounts.isEmpty
        }
    }

    private func apply() {
        switch kind {
        case .type:
            onApply(.setType(type))
            dismiss()
        case .currency:
            onApply(.setCurrency(currency))
            dismiss()
        case .totals:
            onApply(.setIncludeInTotals(includeInTotals))
            dismiss()
        case .archive:
            onApply(.setArchived(isArchived))
            dismiss()
        case .mapToExisting:
            isConfirmingMap = true
        }
    }
}

private struct ImportWizardBulkCategoriesSheet: View {
    let kind: ImportWizardCategoryBulkKind
    let selectedCategories: [LedgerCategory]
    let existingCategories: [LedgerCategory]
    let importedCategories: [LedgerCategory]
    let affectedTransactionCount: Int
    let onApply: (ImportCategoryBulkMutation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID?
    @State private var parentID: UUID?
    @State private var isConfirming = false

    var body: some View {
        Form {
            Section {
                Text("\(selectedCategories.count) provisional categories selected")
                Text("\(affectedTransactionCount) staged transactions use the selected categories. Unused provisional categories can be excluded before import.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            switch kind {
            case .mapToExisting:
                Picker("Existing category", selection: $targetID) {
                    Text("Choose a target").tag(nil as UUID?)
                    CategoryPickerContent(
                        categories: existingCategories.filter { !$0.isArchived },
                        includeUncategorized: false
                    )
                }
            case .parent:
                Picker("Parent category", selection: $parentID) {
                    Text("No parent").tag(nil as UUID?)
                    CategoryPickerContent(
                        categories: (existingCategories + importedCategories).filter { category in
                            !selectedCategories.contains(where: { selected in selected.id == category.id })
                        },
                        includeUncategorized: false
                    )
                }
            case .excludeUnused:
                Label("Only categories with no staged transaction references will be removed.", systemImage: "trash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pocketListSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply() }
                    .disabled(!canApply)
            }
        }
        .confirmationDialog(
            "Confirm category remapping?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Apply") {
                if let targetID { onApply(.mapToExisting(targetID)) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected staged transactions will use the existing category.")
        }
    }

    private var title: String {
        switch kind {
        case .mapToExisting:
            return "Map categories"
        case .parent:
            return "Change parent"
        case .excludeUnused:
            return "Exclude unused"
        }
    }

    private var canApply: Bool {
        switch kind {
        case .mapToExisting:
            return targetID != nil
        case .parent:
            return true
        case .excludeUnused:
            return true
        }
    }

    private func apply() {
        switch kind {
        case .mapToExisting:
            isConfirming = true
        case .parent:
            onApply(.setParent(parentID))
            dismiss()
        case .excludeUnused:
            onApply(.excludeUnused)
            dismiss()
        }
    }
}

private struct ImportWizardReviewContext {
    let accounts: [Account]
    let categories: [LedgerCategory]
    let currencyConflictIndices: Set<Int>
    let suspiciousTransactionIDs: Set<UUID>
    let transactionSearchTextByID: [UUID: String]
}

@MainActor
private struct ImportWizardReviewStep: View {
    @Binding var draft: ImportDraft
    @ObservedObject var store: LedgerStore
    @Binding var rememberRules: Bool

    var body: some View {
        if let data = draft.importedData {
            ImportWizardReviewList(
                draft: $draft,
                store: store,
                rememberRules: $rememberRules,
                data: data,
                context: makeImportWizardReviewContext(data: data, store: store)
            )
        } else {
            ContentUnavailableView("No staged import", systemImage: "doc.questionmark")
        }
    }
}

@MainActor
private struct ImportWizardReviewList: View {
    @Binding var draft: ImportDraft
    @ObservedObject var store: LedgerStore
    @Binding var rememberRules: Bool
    let data: FinanceData
    let context: ImportWizardReviewContext
    @State private var filter: ImportTransactionReviewFilter = .exceptions
    @State private var searchText = ""

    var body: some View {
        List {
            exceptionsSection(context: context)
            summarySection(data: data)
            transactionSection(data: data, context: context)
            Section("Remembered decisions") {
                Toggle("Remember explicit mappings and account edits", isOn: $rememberRules)
                Text("Only changes made in this wizard are saved locally. On-device classifications and transaction data are never stored as rules.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .pocketListSurface()
        .searchable(text: $searchText, prompt: "Search imported transactions")
        .accessibilityIdentifier("importWizard.review")
    }

    @ViewBuilder
    private func summarySection(data: FinanceData) -> some View {
        Section("Final summary") {
            if let summary = draft.finalSummary {
                LabeledContent("Transactions", value: "\(summary.transactionCount)")
                if summary.skippedRowCount > 0 {
                    LabeledContent("Rows skipped", value: "\(summary.skippedRowCount)")
                }
                DisclosureGroup("Import details") {
                    LabeledContent("New active accounts", value: "\(summary.activeAccountCount)")
                    LabeledContent("New archived accounts", value: "\(summary.archivedAccountCount)")
                    LabeledContent("New categories", value: "\(summary.categoryCount)")
                    LabeledContent("Accounts remapped", value: "\(summary.remappedAccountCount)")
                    if summary.skippedRowCount == 0 {
                        LabeledContent("Rows skipped", value: "0")
                    }
                    Text("Archived accounts remain valid for historical rows, but they are excluded from active account choices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Review highlighted exceptions before importing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func exceptionsSection(context: ImportWizardReviewContext) -> some View {
        Section("Review") {
            let currencyConflictCount = context.currencyConflictIndices.count
            Picker("Transaction rows", selection: $filter) {
                ForEach(ImportTransactionReviewFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if let warnings = draft.result?.warnings, !warnings.isEmpty {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if currencyConflictCount > 0 {
                Label("\(currencyConflictCount) transaction rows have account/currency conflicts.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !draft.duplicateTransactionIDs.isEmpty {
                Label("\(draft.duplicateTransactionIDs.count) possible duplicates need a decision.", systemImage: "doc.on.doc")
                    .foregroundStyle(.orange)
            }
            if !context.suspiciousTransactionIDs.isEmpty {
                Label("\(context.suspiciousTransactionIDs.count) rows exceed $1,000 USD equivalent; check their currency.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("These are review reminders and do not block the import.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if (draft.result?.skippedRows ?? 0) > 0 {
                Label("\(draft.result?.skippedRows ?? 0) rows were skipped while parsing and are not importable.", systemImage: "arrow.uturn.right")
                    .foregroundStyle(.secondary)
            }
            if draft.duplicateTransactionIDs.isEmpty,
               currencyConflictCount == 0,
               (draft.result?.skippedRows ?? 0) == 0 {
                Label("No unresolved exceptions found.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func transactionSection(data: FinanceData, context: ImportWizardReviewContext) -> some View {
        Section("Transactions") {
            let indices = filteredTransactionIndices(data: data, context: context)
            if filter == .skipped {
                Text("Correct skipped rows in your source file, cancel this review, and import the corrected file. Skipped rows won’t be imported.")
                    .foregroundStyle(.secondary)
            } else if indices.isEmpty {
                Text("No transaction rows match this filter.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(indices, id: \.self) { index in
                    ImportWizardTransactionRow(
                        transaction: transactionBinding(at: index),
                        accounts: context.accounts,
                        categories: context.categories,
                        isDuplicate: draft.duplicateTransactionIDs.contains(data.transactions[index].id),
                        isSuspiciousLargeAmount: context.suspiciousTransactionIDs.contains(data.transactions[index].id),
                        isExcluded: draft.excludedDuplicateIDs.contains(data.transactions[index].id),
                        exchangeRates: store.data.exchangeRates + data.exchangeRates,
                        onToggleExcluded: {
                            toggleDuplicate(data.transactions[index].id)
                        }
                    )
                }
            }
        }
    }

    private func filteredTransactionIndices(data: FinanceData, context: ImportWizardReviewContext) -> [Int] {
        let matchingIndices = data.transactions.indices.filter { index in
            matchesSearch(data.transactions[index], context: context)
        }
        switch filter {
        case .exceptions:
            return matchingIndices.filter {
                draft.duplicateTransactionIDs.contains(data.transactions[$0].id)
                    || context.currencyConflictIndices.contains($0)
                    || context.suspiciousTransactionIDs.contains(data.transactions[$0].id)
            }
        case .all:
            return Array(matchingIndices)
        case .duplicates:
            return matchingIndices.filter {
                draft.duplicateTransactionIDs.contains(data.transactions[$0].id)
            }
        case .skipped:
            return []
        }
    }

    private func matchesSearch(_ transaction: LedgerTransaction, context: ImportWizardReviewContext) -> Bool {
        guard !searchText.isEmpty else { return true }
        return context.transactionSearchTextByID[transaction.id, default: ""]
            .localizedCaseInsensitiveContains(searchText)
    }

    private func transactionBinding(at index: Int) -> Binding<LedgerTransaction> {
        Binding(
            get: { draft.importedData!.transactions[index] },
            set: { draft.importedData!.transactions[index] = $0 }
        )
    }

    private func toggleDuplicate(_ id: UUID) {
        if draft.excludedDuplicateIDs.contains(id) {
            draft.excludedDuplicateIDs.remove(id)
        } else {
            draft.excludedDuplicateIDs.insert(id)
        }
    }
}

@MainActor
private func makeImportWizardReviewContext(
    data: FinanceData,
    store: LedgerStore
) -> ImportWizardReviewContext {
    var accountsByID: [UUID: Account] = [:]
    for account in data.accounts {
        accountsByID[account.id] = account
    }
    for account in store.data.accounts {
        accountsByID[account.id] = account
    }

    var categoriesByID: [UUID: LedgerCategory] = [:]
    for category in data.categories {
        categoriesByID[category.id] = category
    }
    for category in store.data.categories {
        categoriesByID[category.id] = category
    }

    let currencyConflictIndices = Set(data.transactions.indices.filter { index in
        let transaction = data.transactions[index]
        let movements = transaction.outflows + transaction.inflows
        return movements.contains { movement in
            guard let account = accountsByID[movement.accountID] else { return true }
            guard account.currency != movement.money.currency else { return false }
            return financeConvertedMinorUnits(
                movement.money,
                to: account.currency,
                using: transaction.exchangeRate
            ) == nil
        }
    })

    var transactionSearchTextByID: [UUID: String] = [:]
    for transaction in data.transactions {
        let movements = transaction.outflows + transaction.inflows
        let accountText = Set(movements.map(\.accountID))
            .compactMap { accountsByID[$0]?.name }
            .joined(separator: " ")
        let categoryText = transaction.categoryID
            .flatMap { categoriesByID[$0]?.name }
            ?? ""
        let amountText = movements.map { $0.money.formatted }.joined(separator: " ")
        transactionSearchTextByID[transaction.id] = [
            transaction.note,
            accountText,
            categoryText,
            amountText
        ].joined(separator: " ")
    }

    return ImportWizardReviewContext(
        accounts: accountsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        },
        categories: categoriesByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        },
        currencyConflictIndices: currencyConflictIndices,
        suspiciousTransactionIDs: FinanceImportReview.suspiciousLargeAmountTransactionIDs(in: data),
        transactionSearchTextByID: transactionSearchTextByID
    )
}

private struct ImportWizardTransactionRow: View {
    @Binding var transaction: LedgerTransaction
    let accounts: [Account]
    let categories: [LedgerCategory]
    let isDuplicate: Bool
    let isSuspiciousLargeAmount: Bool
    let isExcluded: Bool
    let exchangeRates: [ExchangeRate]
    let onToggleExcluded: () -> Void

    var body: some View {
        DisclosureGroup {
            if !transaction.outflows.isEmpty {
                Picker("Source account", selection: sourceAccountBinding) {
                    ForEach(accountOptions(
                        for: transaction.outflows[0].accountID,
                        movementCurrency: transaction.outflows[0].money.currency
                    )) { account in
                        Text(accountLabel(account)).tag(Optional(account.id))
                    }
                }
                Picker("Payment currency", selection: sourceCurrencyBinding) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
            }
            if transaction.kind == .transfer, !transaction.inflows.isEmpty {
                Picker("Destination account", selection: destinationAccountBinding) {
                    ForEach(accountOptions(
                        for: transaction.inflows[0].accountID,
                        movementCurrency: transaction.inflows[0].money.currency
                    )) { account in
                        Text(accountLabel(account)).tag(Optional(account.id))
                    }
                }
                Picker("Received currency", selection: destinationCurrencyBinding) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
            } else if transaction.outflows.isEmpty, !transaction.inflows.isEmpty {
                Picker("Destination account", selection: destinationAccountBinding) {
                    ForEach(accountOptions(
                        for: transaction.inflows[0].accountID,
                        movementCurrency: transaction.inflows[0].money.currency
                    )) { account in
                        Text(accountLabel(account)).tag(Optional(account.id))
                    }
                }
                Picker("Received currency", selection: destinationCurrencyBinding) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
            }
            Picker("Category", selection: $transaction.categoryID) {
                CategoryPickerContent(categories: categories)
            }
            if isDuplicate {
                Toggle("Skip possible duplicate", isOn: Binding(
                    get: { isExcluded },
                    set: { _ in onToggleExcluded() }
                ))
            }
            if isSuspiciousLargeAmount {
                Label("Check currency: this is over $1,000 USD equivalent.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(transaction.note.isEmpty ? transaction.kind.displayName : transaction.note)
                        .lineLimit(1)
                    Text(transactionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDuplicate {
                    Image(systemName: isExcluded ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(isExcluded ? .green : .orange)
                }
                if isSuspiciousLargeAmount {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var sourceAccountBinding: Binding<UUID?> {
        Binding(
            get: { transaction.outflows.first?.accountID },
            set: { accountID in
                var movements = transaction.outflows
                updateMovement(in: &movements, to: accountID)
                transaction.outflows = movements
            }
        )
    }

    private var destinationAccountBinding: Binding<UUID?> {
        Binding(
            get: { transaction.inflows.first?.accountID },
            set: { accountID in
                var movements = transaction.inflows
                updateMovement(in: &movements, to: accountID)
                transaction.inflows = movements
            }
        )
    }

    private var sourceCurrencyBinding: Binding<LedgerCurrency> {
        Binding(
            get: { transaction.outflows.first?.money.currency ?? .usd },
            set: { currency in
                var movements = transaction.outflows
                updateMovementCurrency(in: &movements, to: currency)
                transaction.outflows = movements
                updateExchangeRateIfNeeded()
            }
        )
    }

    private var destinationCurrencyBinding: Binding<LedgerCurrency> {
        Binding(
            get: { transaction.inflows.first?.money.currency ?? .usd },
            set: { currency in
                var movements = transaction.inflows
                updateMovementCurrency(in: &movements, to: currency)
                transaction.inflows = movements
                updateExchangeRateIfNeeded()
            }
        )
    }

    private var transactionSummary: String {
        let movement = transaction.outflows.first ?? transaction.inflows.first
        let amount = movement?.money.formatted ?? "—"
        return "\(transaction.date.formatted(date: .abbreviated, time: .omitted)) · \(amount)"
    }

    private func accountOptions(
        for currentID: UUID,
        movementCurrency: LedgerCurrency
    ) -> [Account] {
        accounts.filter { account in
            (!account.isArchived || account.id == currentID)
                && (account.currency == movementCurrency || account.id == currentID)
        }
    }

    private func accountLabel(_ account: Account) -> String {
        "\(account.name) · \(account.currency.rawValue)\(account.isArchived ? " · Archived" : "")"
    }

    private func updateMovement(in movements: inout [MoneyMovement], to accountID: UUID?) {
        guard let accountID,
              let index = movements.indices.first,
              accounts.contains(where: { $0.id == accountID }) else { return }
        movements[index].accountID = accountID
    }

    private func updateMovementCurrency(in movements: inout [MoneyMovement], to currency: LedgerCurrency) {
        guard let index = movements.indices.first,
              movements[index].money.currency != currency else { return }
        movements[index].money = movements[index].money.recast(to: currency)
    }

    private func updateExchangeRateIfNeeded() {
        let movements = transaction.outflows + transaction.inflows
        guard let firstMovement = movements.first else { return }

        if transaction.kind == .transfer,
           let destination = transaction.inflows.first,
           firstMovement.money.currency != destination.money.currency,
           financeConvertedMinorUnits(
               firstMovement.money,
               to: destination.money.currency,
               using: transaction.exchangeRate
           ) == nil,
           let rate = storedExchangeRate(
               from: firstMovement.money.currency,
               to: destination.money.currency
           ) {
            transaction.exchangeRate = rate
            return
        }

        guard let account = accounts.first(where: { $0.id == firstMovement.accountID }),
              account.currency != firstMovement.money.currency,
              financeConvertedMinorUnits(
                  firstMovement.money,
                  to: account.currency,
                  using: transaction.exchangeRate
              ) == nil,
              let rate = storedExchangeRate(
                  from: firstMovement.money.currency,
                  to: account.currency
              ) else { return }
        transaction.exchangeRate = rate
    }

    private func storedExchangeRate(from baseCurrency: LedgerCurrency, to quoteCurrency: LedgerCurrency) -> ExchangeRate? {
        guard baseCurrency != quoteCurrency else { return nil }
        if let exact = exchangeRates.first(where: {
            $0.baseCurrency == baseCurrency && $0.quoteCurrency == quoteCurrency
        }) {
            return exact
        }
        guard let reverse = exchangeRates.first(where: {
            $0.baseCurrency == quoteCurrency && $0.quoteCurrency == baseCurrency
        }), reverse.quoteUnitsPerBaseUnit > 0 else {
            return nil
        }
        return ExchangeRate(
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            quoteUnitsPerBaseUnit: Decimal(1) / reverse.quoteUnitsPerBaseUnit
        )
    }
}
