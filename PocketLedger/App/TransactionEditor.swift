import Foundation
import AppIntents
import SwiftUI
import UniformTypeIdentifiers

private struct MovementDraft: Identifiable, Equatable {
    let id: UUID
    var accountID: UUID
    var currency: LedgerCurrency
    var amount: String
    var categoryID: UUID?
    var hasCategoryAssignment: Bool

    init(
        id: UUID = UUID(),
        accountID: UUID,
        currency: LedgerCurrency,
        amount: String,
        categoryID: UUID? = nil,
        hasCategoryAssignment: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.currency = currency
        self.amount = amount
        self.categoryID = categoryID
        self.hasCategoryAssignment = hasCategoryAssignment
    }
}

enum FinanceTransactionDefaults {
    static func primaryAccount(
        in accounts: [Account],
        sourceAccountID: UUID?,
        scheduledAccountID: UUID?,
        rememberedAccountID: UUID?,
        preferredCurrency: LedgerCurrency?
    ) -> Account? {
        if let id = sourceAccountID ?? scheduledAccountID,
           let account = accounts.first(where: { $0.id == id }) {
            return account
        }
        if let rememberedAccountID,
           let account = accounts.first(where: {
               $0.id == rememberedAccountID
                   && !$0.isArchived
                   && (preferredCurrency == nil || $0.currency == preferredCurrency)
           }) {
            return account
        }
        return accounts.first { account in
            !account.isArchived && (preferredCurrency == nil || account.currency == preferredCurrency)
        }
    }

    static func categoryID(
        sourceTransaction: LedgerTransaction?,
        scheduledTransaction: ScheduledTransaction?,
        rememberedCategoryID: UUID?,
        activeCategories: [LedgerCategory]
    ) -> UUID? {
        if let sourceTransaction { return sourceTransaction.categoryID }
        if let scheduledTransaction { return scheduledTransaction.categoryID }
        return rememberedCategoryID.flatMap { id in activeCategories.first(where: { $0.id == id })?.id }
            ?? activeCategories.first(where: { $0.parentID != nil })?.id
            ?? activeCategories.first?.id
    }
}

private struct PendingAttachmentReplacement: Equatable {
    let data: Data
    let fileName: String
    let contentType: String
}

private struct TransactionEditorSnapshot: Equatable {
    let templateName: String
    let note: String
    let date: Date
    let kind: TransactionKind
    let timing: TransactionTiming
    let scheduleFrequency: ScheduleFrequency
    let monthlyRule: ScheduleMonthlyRule
    let scheduleEnabled: Bool
    let categoryID: UUID?
    let dueCurrency: LedgerCurrency
    let amountDue: String
    let outflows: [MovementDraft]
    let inflows: [MovementDraft]
    let requestedChange: String
    let useCustomRate: Bool
    let rateBase: LedgerCurrency
    let rateQuote: LedgerCurrency
    let rateText: String
    let attachmentIDs: [UUID]
    let deletedAttachmentIDs: Set<UUID>
    let attachmentReplacements: [UUID: PendingAttachmentReplacement]
}

@MainActor
private struct MovementLineEditor: View {
    @ObservedObject var store: LedgerStore
    @Binding var line: MovementDraft
    let amountPlaceholder: String
    let allowsArchivedAccount: Bool
    var focusAmountOnAppear = false

    var body: some View {
        let availableCurrencies = LedgerCurrency.allCases.filter { currency in
            store.activeAccounts.contains { $0.currency == currency }
                || (allowsArchivedAccount && store.account(with: line.accountID)?.currency == currency)
        }

        return VStack(alignment: .leading, spacing: 8) {
            CurrencyInputField(
                amountPlaceholder,
                text: $line.amount,
                currency: Binding(
                    get: { line.currency },
                    set: { currency in
                        line.currency = currency
                        if let account = store.activeAccounts.first(where: { $0.currency == currency }) {
                            line.accountID = account.id
                        }
                    }
                ),
                selectableCurrencies: availableCurrencies,
                focusOnAppear: focusAmountOnAppear
            )
            if !line.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let amount = Money.parse(line.amount, currency: line.currency), amount.minorUnits <= 0 {
                Label("Enter an amount greater than zero.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.warning)
            } else if !line.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      Money.parse(line.amount, currency: line.currency) == nil {
                Label("Enter a valid amount in \(line.currency.rawValue).", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.warning)
            }

            Picker("Account", selection: $line.accountID) {
                ForEach(store.data.accounts.filter { account in
                    account.currency == line.currency
                        && (!account.isArchived || (allowsArchivedAccount && account.id == line.accountID))
                }) { account in
                    Text("\(account.name) (\(account.currency.rawValue))")
                        .tag(account.id)
                }
            }
            .pickerStyle(.menu)
            if !store.data.accounts.contains(where: { $0.id == line.accountID && $0.currency == line.currency }) {
                Label("Choose an account that uses \(line.currency.rawValue).", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.warning)
            }
        }
    }
}

private enum TransactionEditorType: String, CaseIterable, Identifiable, Hashable {
    case expense
    case income
    case transfer
    case loan

    var id: String { rawValue }

    var displayName: String {
        guard let transactionKind else { return "Loan" }
        return transactionKind.displayName
    }

    var transactionKind: TransactionKind? {
        switch self {
        case .expense: return .expense
        case .income: return .income
        case .transfer: return .transfer
        case .loan: return nil
        }
    }

    init(_ kind: TransactionKind) {
        switch kind {
        case .expense: self = .expense
        case .income: self = .income
        case .transfer: self = .transfer
        }
    }
}

@MainActor
struct TransactionEditor: View {
    private static let lastAccountKey = "pocketLedger.lastTransactionAccount"
    private static let lastCategoryKey = "pocketLedger.lastExpenseCategory"

    @ObservedObject var store: LedgerStore
    @ObservedObject private var proAccess = ProEntitlementStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var templateName = ""
    @State private var date = Date.now
    @State private var kind: TransactionKind = .expense
    @State private var isPresentingLoanEditor = false
    @State private var loanCreatedNotice = false
    @State private var timing: TransactionTiming = .now
    @State private var scheduleFrequency: ScheduleFrequency = .once
    @State private var monthlyRule: ScheduleMonthlyRule = .dayOfMonth
    @State private var scheduleEnabled = true
    @State private var categoryID: UUID?
    @State private var selectedPaymentCategoryIndex: Int?
    @State private var isSelectingCategory = false
    @State private var dueCurrency: LedgerCurrency = .usd
    @State private var amountDue = ""
    @State private var outflows: [MovementDraft]
    @State private var inflows: [MovementDraft] = []
    @State private var requestedChange = ""
    @State private var useCustomRate = true
    @State private var automaticTransferDestinationAmount: String?
    @State private var rateBase: LedgerCurrency = .usd
    @State private var rateQuote: LedgerCurrency = .lbp
    @State private var rateText = "100000"
    @State private var attachmentIDs: [UUID]
    @State private var previewAttachment: LedgerAttachment?
    @State private var isShowingAttachmentImporter = false
    @State private var replacingAttachmentID: UUID?
    @State private var attachmentIDsPendingDeletion: Set<UUID> = []
    @State private var attachmentReplacements: [UUID: PendingAttachmentReplacement] = [:]
    @State private var originalEditorSnapshot: TransactionEditorSnapshot?
    @State private var isShowingDiscardConfirmation = false
    @State private var isShowingProUpgrade = false
    @State private var errorMessage: String?
    @State private var isShowingMoreDetails = false
    @State private var saveFeedbackTrigger = 0
    private let editingScheduleID: UUID?
    private let editingScheduleLastRunDate: Date?
    private let editingScheduleNextRunDate: Date?
    private let editingScheduleFrequency: ScheduleFrequency?
    private let editingScheduleRecurrenceDay: Int?
    private let editingScheduleReminderTiming: ScheduledReminderTiming?
    private let editingTransactionID: UUID?
    private let editingTemplateID: UUID?
    private let isCreatingTemplate: Bool
    private let hasPrefilledTransactionContent: Bool
    private let initialAttachmentData: Data?
    private let initialAttachmentFileName: String?
    private let initialAttachmentContentType: String?
    private let initialReceiptItems: [LedgerReceiptLineItem]

    init(
        store: LedgerStore,
        initialKind: TransactionKind = .expense,
        initialAmount: Money? = nil,
        initialBillTotal: Money? = nil,
        initialNote: String? = nil,
        initialTiming: TransactionTiming = .now,
        initialFrequency: ScheduleFrequency = .once,
        scheduledTransaction: ScheduledTransaction? = nil,
        transaction: LedgerTransaction? = nil,
        prefilledTransaction: LedgerTransaction? = nil,
        template: LedgerTemplate? = nil,
        editingTemplate: LedgerTemplate? = nil,
        createTemplate: Bool = false,
        initialAttachmentData: Data? = nil,
        initialAttachmentFileName: String? = nil,
        initialAttachmentContentType: String? = nil,
        initialReceiptItems: [LedgerReceiptLineItem] = [],
        initialLoanEntry: Bool = false
    ) {
        _store = ObservedObject(wrappedValue: store)
        let sourceTransaction = transaction ?? prefilledTransaction
            ?? editingTemplate?.transactionTemplate
            ?? template?.transactionTemplate
        let rememberedAccount = UserDefaults.standard.string(forKey: Self.lastAccountKey)
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in store.activeAccounts.first(where: { $0.id == id }) }
        let preferredCurrency = sourceTransaction?.outflows.first?.money.currency
            ?? sourceTransaction?.inflows.first?.money.currency
            ?? scheduledTransaction?.outflows.first?.money.currency
            ?? scheduledTransaction?.inflows.first?.money.currency
            ?? initialAmount?.currency
            ?? rememberedAccount?.currency
        let existingAccountID = sourceTransaction?.outflows.first?.accountID
            ?? sourceTransaction?.inflows.first?.accountID
            ?? scheduledTransaction?.outflows.first?.accountID
            ?? scheduledTransaction?.inflows.first?.accountID
        let firstAccount = FinanceTransactionDefaults.primaryAccount(
            in: store.data.accounts,
            sourceAccountID: sourceTransaction == nil ? nil : existingAccountID,
            scheduledAccountID: scheduledTransaction == nil ? nil : existingAccountID,
            rememberedAccountID: rememberedAccount?.id,
            preferredCurrency: preferredCurrency
        )
        let firstAccountID = firstAccount?.id ?? UUID()
        let resolvedInitialKind = sourceTransaction?.kind ?? scheduledTransaction?.kind ?? initialKind
        let initialDestinationAccount = store.activeAccounts.first { account in
            account.id != firstAccountID
        } ?? firstAccount
        let initialDestinationAccountID = initialDestinationAccount?.id ?? firstAccountID
        let amountDue = sourceTransaction?.amountDue ?? scheduledTransaction?.amountDue ?? initialBillTotal
        let initialCurrencies = LedgerCurrency.allCases.filter { currency in
            let initialOutflows = sourceTransaction?.outflows ?? scheduledTransaction?.outflows ?? []
            let initialInflows = sourceTransaction?.inflows ?? scheduledTransaction?.inflows ?? []
            return initialOutflows.contains { $0.money.currency == currency }
                || initialInflows.contains { $0.money.currency == currency }
                || initialOutflows.contains { store.account(with: $0.accountID)?.currency == currency }
                || initialInflows.contains { store.account(with: $0.accountID)?.currency == currency }
                || (resolvedInitialKind == .transfer && [
                    firstAccount?.currency,
                    initialDestinationAccount?.currency
                ].compactMap { $0 }.contains(currency))
        }
        let initialRateBase = sourceTransaction?.exchangeRate?.baseCurrency
            ?? scheduledTransaction?.exchangeRate?.baseCurrency
            ?? initialCurrencies.first
            ?? .usd
        let initialRateQuote = sourceTransaction?.exchangeRate?.quoteCurrency
            ?? scheduledTransaction?.exchangeRate?.quoteCurrency
            ?? initialCurrencies.first(where: { $0 != initialRateBase })
            ?? (initialRateBase == .usd ? .lbp : .usd)
        let initialSavedRate = sourceTransaction?.exchangeRate
            ?? scheduledTransaction?.exchangeRate
            ?? store.exchangeRate(base: initialRateBase, quote: initialRateQuote)
        let rememberedCategoryID = UserDefaults.standard.string(forKey: Self.lastCategoryKey)
            .flatMap(UUID.init(uuidString:))
        let initialCategoryID = FinanceTransactionDefaults.categoryID(
            sourceTransaction: sourceTransaction,
            scheduledTransaction: scheduledTransaction,
            rememberedCategoryID: rememberedCategoryID,
            activeCategories: store.activeCategories
        )
        let assignsPaymentCategories = !createTemplate
            && editingTemplate == nil
            && transaction == nil
            && scheduledTransaction == nil
            && resolvedInitialKind == .expense
            && initialTiming == .now
        _note = State(initialValue: sourceTransaction?.note ?? scheduledTransaction?.note ?? initialNote ?? "")
        _templateName = State(initialValue: editingTemplate?.name ?? "")
        _date = State(initialValue: transaction?.date ?? scheduledTransaction?.nextRunDate ?? .now)
        _kind = State(initialValue: resolvedInitialKind)
        _isPresentingLoanEditor = State(initialValue: initialLoanEntry)
        _timing = State(initialValue: transaction == nil && scheduledTransaction == nil ? initialTiming : transaction == nil ? .scheduled : .now)
        _scheduleFrequency = State(initialValue: scheduledTransaction?.frequency ?? initialFrequency)
        _monthlyRule = State(initialValue: scheduledTransaction?.monthlyRule ?? .dayOfMonth)
        _scheduleEnabled = State(initialValue: scheduledTransaction?.isEnabled ?? true)
        _dueCurrency = State(initialValue: amountDue?.currency ?? preferredCurrency ?? .usd)
        _amountDue = State(initialValue: amountDue.map { Self.inputText(for: $0) } ?? "")
        _outflows = State(
            initialValue: (sourceTransaction?.outflows ?? scheduledTransaction?.outflows)?.map {
                MovementDraft(
                    id: $0.id,
                    accountID: $0.accountID,
                    currency: $0.money.currency,
                    amount: Self.inputText(for: $0.money),
                    categoryID: $0.hasCategoryAssignment ? $0.categoryID : initialCategoryID,
                    hasCategoryAssignment: $0.hasCategoryAssignment || assignsPaymentCategories
                )
            } ?? [
                MovementDraft(
                    accountID: firstAccountID,
                    currency: initialAmount?.currency ?? firstAccount?.currency ?? preferredCurrency ?? .usd,
                    amount: initialAmount.map { Self.inputText(for: $0) } ?? "",
                    categoryID: initialCategoryID,
                    hasCategoryAssignment: assignsPaymentCategories
                )
            ]
        )
        _inflows = State(
            initialValue: (sourceTransaction?.inflows ?? scheduledTransaction?.inflows)?.map {
                MovementDraft(
                    accountID: $0.accountID,
                    currency: $0.money.currency,
                    amount: Self.inputText(for: $0.money)
                )
            } ?? (resolvedInitialKind == .transfer
                ? [
                    MovementDraft(
                        accountID: initialDestinationAccountID,
                        currency: initialDestinationAccount?.currency ?? .usd,
                        amount: ""
                    )
                ]
                : [])
        )
        let initialInflows = sourceTransaction?.inflows ?? scheduledTransaction?.inflows ?? []
        let initialHasAttachments = !(transaction?.attachmentIDs ?? []).isEmpty
            || initialAttachmentData != nil
        _isShowingMoreDetails = State(initialValue:
            resolvedInitialKind != .expense
                || initialTiming == .scheduled
                || scheduledTransaction != nil
                || !initialInflows.isEmpty
                || sourceTransaction?.changeAdjustment != nil
                || sourceTransaction?.exchangeRate != nil
                || scheduledTransaction?.exchangeRate != nil
                || amountDue != nil
                || initialHasAttachments
                || initialCurrencies.count > 1
                || !initialReceiptItems.isEmpty
        )
        _requestedChange = State(
            initialValue: (sourceTransaction?.changeAdjustment ?? scheduledTransaction?.changeAdjustment).map { Self.inputText(for: $0.requested) } ?? ""
        )
        _rateBase = State(initialValue: initialRateBase)
        _rateQuote = State(initialValue: initialRateQuote)
        _useCustomRate = State(
            initialValue: resolvedInitialKind == .transfer
                ? sourceTransaction?.exchangeRate != nil
                    || scheduledTransaction?.exchangeRate != nil
                : true
        )
        _rateText = State(
            initialValue: initialSavedRate.map {
                NSDecimalNumber(decimal: $0.quoteUnitsPerBaseUnit).stringValue
            } ?? "100000"
        )
        _attachmentIDs = State(initialValue: transaction?.attachmentIDs ?? [])
        _categoryID = State(
            initialValue: initialCategoryID
        )
        _selectedPaymentCategoryIndex = State(initialValue: nil)
        editingScheduleID = scheduledTransaction?.id
        editingScheduleLastRunDate = scheduledTransaction?.lastRunDate
        editingScheduleNextRunDate = scheduledTransaction?.nextRunDate
        editingScheduleFrequency = scheduledTransaction?.frequency
        editingScheduleRecurrenceDay = scheduledTransaction?.recurrenceDay
        editingScheduleReminderTiming = scheduledTransaction?.reminderTiming
        editingTransactionID = transaction?.id
        editingTemplateID = editingTemplate?.id
        isCreatingTemplate = createTemplate
        hasPrefilledTransactionContent = sourceTransaction != nil
        self.initialAttachmentData = initialAttachmentData
        self.initialAttachmentFileName = initialAttachmentFileName
        self.initialAttachmentContentType = initialAttachmentContentType
        self.initialReceiptItems = initialReceiptItems
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: transactionEditorTypeBinding) {
                        ForEach(availableTransactionEditorTypes) { editorType in
                            Text(editorType.displayName).tag(editorType)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Transaction type")
                }

                if isPresentingLoanEditor {
                    LoanEditor(store: store, onSave: {
                        if hasUnsavedChanges {
                            loanCreatedNotice = true
                            isPresentingLoanEditor = false
                        } else {
                            dismiss()
                        }
                    }, isEmbedded: true)
                } else {
                    if loanCreatedNotice {
                        Section {
                            Label("Loan created. Your transaction draft is still open.", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(PocketLedgerTheme.positive)
                        }
                    }

                    if let saveValidationMessage {
                        Section(hasUnsavedChanges || editingTransactionID != nil || editingTemplateID != nil || isEditingScheduledTransaction
                            ? "Save needs attention"
                            : "To save") {
                            Label(saveValidationMessage, systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                    }

                    if isTemplateEditor {
                        Section("Template") {
                            TextField("Template name", text: $templateName)
                        }
                    }

                    if kind == .expense {
                        expensePaymentsSection
                        detailsSection
                        expenseDateSection
                        moreDetailsSection
                    } else {
                        timingSection
                        detailsSection
                        attachmentSection
                        outgoingMovementSection
                        receivingMovementSection
                        exchangeRateSection
                    }
                }

            }
            .onAppear {
                if kind == .transfer && inflows.isEmpty {
                    inflows.append(newReceivingMovementDraft)
                }
                synchronizeRatePair()
                synchronizeAutomaticTransferAmount()
                if originalEditorSnapshot == nil {
                    originalEditorSnapshot = editorSnapshot
                }
            }
            .onChange(of: kind) { _, newKind in
                handleKindChange(newKind)
            }
            .onChange(of: selectedCurrencies) { _, _ in
                if kind == .expense && selectedCurrencies.count > 1 {
                    isShowingMoreDetails = true
                }
                synchronizeRatePair()
                synchronizeAutomaticTransferAmount()
            }
            .onChange(of: outflows) { _, _ in
                synchronizeAutomaticTransferAmount()
            }
            .onChange(of: inflows) { oldInflows, newInflows in
                if kind == .expense && !newInflows.isEmpty {
                    isShowingMoreDetails = true
                }
                let amountWasEdited = oldInflows.first?.amount != newInflows.first?.amount
                if amountWasEdited,
                   newInflows.first?.amount != automaticTransferDestinationAmount {
                    self.automaticTransferDestinationAmount = nil
                    synchronizeRatePair()
                    return
                }
                synchronizeRatePair()
                synchronizeAutomaticTransferAmount()
            }
            .onChange(of: useCustomRate) { _, _ in
                if useCustomRate {
                    prepareCustomRate()
                }
                synchronizeAutomaticTransferAmount()
            }
            .onChange(of: rateText) { _, _ in
                guard useCustomRate else { return }
                synchronizeAutomaticTransferAmount()
            }
            .interactiveDismissDisabled(hasUnsavedChanges)
            .pocketListSurface()
            .navigationTitle(isPresentingLoanEditor ? "New loan" : navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.success, trigger: saveFeedbackTrigger)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                if !isPresentingLoanEditor {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveButtonTitle, action: save)
                            .disabled(!canSave)
                    }
                }
            }
            .errorMessageAlert(title: "Transaction not saved", message: $errorMessage)
            .confirmationDialog(
                "Discard changes?",
                isPresented: $isShowingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your transaction and receipt changes have not been saved.")
            }
            .sheet(item: $previewAttachment) { attachment in
                NavigationStack {
                    AttachmentPreviewView(store: store, attachment: attachment)
                }
            }
            .sheet(isPresented: $isSelectingCategory) {
                CategorySelectionSheet(
                    categories: selectableCategories,
                    selectedCategoryID: categorySelectionBinding,
                    includeUncategorized: true
                )
            }
            .background {
                Color.clear.sheet(isPresented: $isShowingProUpgrade) {
                    ProUpgradeView(access: proAccess)
                }
            }
            .fileImporter(
                isPresented: $isShowingAttachmentImporter,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: false,
                onCompletion: replaceAttachment
            )
        }
        .userActivity(
            "com.josephlteif.pocketledger.viewing-transaction",
            element: visibleTransactionEntity
        ) { entity, activity in
            activity.title = "Viewing \(entity.note.isEmpty ? entity.kind : entity.note)"
            activity.appEntityIdentifier = EntityIdentifier(for: entity)
        }
    }

    private var visibleTransactionEntity: FinanceTransactionEntity? {
        guard let editingTransactionID,
              let transaction = store.data.transactions.first(where: { $0.id == editingTransactionID }) else {
            return nil
        }
        return FinanceTransactionEntity(transaction: transaction, data: store.data)
    }

    private var transactionEditorTypeBinding: Binding<TransactionEditorType> {
        Binding(
            get: { isPresentingLoanEditor ? .loan : TransactionEditorType(kind) },
            set: { editorType in
                if editorType == .loan {
                    isPresentingLoanEditor = true
                } else if let transactionKind = editorType.transactionKind {
                    isPresentingLoanEditor = false
                    kind = transactionKind
                }
            }
        )
    }

    private var availableTransactionEditorTypes: [TransactionEditorType] {
        guard editingTransactionID == nil,
              !isEditingScheduledTransaction,
              !isTemplateEditor,
              !hasPrefilledTransactionContent else {
            return TransactionEditorType.allCases.filter { $0 != .loan }
        }
        return TransactionEditorType.allCases
    }

    private var isEditingScheduledTransaction: Bool {
        editingScheduleID != nil
    }

    @ViewBuilder
    private var timingSection: some View {
        Section("Timing") {
            timingPicker

            if timing == .scheduled {
                DatePicker("First run", selection: $date, displayedComponents: [.date, .hourAndMinute])
            } else {
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }

            scheduleRepeatFields
        }
    }

    private var timingPicker: some View {
        Picker("When", selection: $timing) {
            ForEach(TransactionTiming.allCases) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isEditingScheduledTransaction)
    }

    @ViewBuilder
    private var scheduleRepeatFields: some View {
        if timing == .scheduled {
            Picker("Repeats", selection: $scheduleFrequency) {
                ForEach(ScheduleFrequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }

            if scheduleFrequency == .monthly {
                Picker("Monthly rule", selection: $monthlyRule) {
                    ForEach(ScheduleMonthlyRule.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }

                Text(monthlyScheduleDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("Enabled", isOn: $scheduleEnabled)
                .disabled(completedOneTimeSchedule)

            if completedOneTimeSchedule {
                Text("This one-time schedule has already been added to transactions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var expensePaymentsSection: some View {
        Section(
            header: Text(outflows.count > 1 ? "Payment breakdown" : "Payment"),
            footer: Text(outflows.isEmpty
                         ? "Choose the account this purchase was paid from."
                         : supportsPaymentCategories
                            ? "Choose a category for each payment. New payments start with the main payment's category."
                            : outflows.count > 1
                                ? "These amounts combine into one purchase total. Each part can use a different account or currency."
                                : "Add another part only if you paid from more than one account."),
            content: {
            if outflows.isEmpty {
                Button("Choose payment account") {
                    outflows.append(newSplitPaymentDraft)
                }
            } else {
                ForEach(Array(outflows.enumerated()), id: \.element.id) { entry in
                    let index = entry.offset
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(index == 0 ? "Main payment" : "Additional payment \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if outflows.count > 1 {
                                removeLineButton(
                                    accessibilityLabel: "Remove payment \(index + 1)"
                                ) {
                                    outflows.remove(at: index)
                                    if index == 0,
                                       let mainPayment = outflows.first,
                                       mainPayment.hasCategoryAssignment {
                                        categoryID = mainPayment.categoryID
                                    }
                                }
                            }
                        }

                        MovementLineEditor(
                            store: store,
                            line: $outflows[index],
                            amountPlaceholder: index == 0 ? "Amount" : "Amount for this payment",
                            allowsArchivedAccount: allowsArchivedMovementAccounts,
                            focusAmountOnAppear: index == 0 && outflows[index].amount.isEmpty
                        )
                        if supportsPaymentCategories {
                            paymentCategorySelector(at: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !outflows.isEmpty {
                Button {
                    outflows.append(newSplitPaymentDraft)
                } label: {
                    Label(
                        outflows.count > 1 ? "Add another payment" : "Split this payment",
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
            })
    }

    private var expenseDateSection: some View {
        Section("Date") {
            DatePicker(
                timing == .scheduled ? "First run" : "Date",
                selection: $date,
                displayedComponents: timing == .scheduled ? [.date, .hourAndMinute] : [.date]
            )
        }
    }

    private var moreDetailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isShowingMoreDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    expenseScheduleDetails
                    Divider()
                    expenseBillDetails
                    Divider()
                    expenseReturnedMoneyDetails
                    if !attachments.isEmpty || initialAttachmentFileName != nil {
                        Divider()
                        expenseAttachmentDetails
                    }
                    if selectedCurrencies.count > 1 {
                        Divider()
                        exchangeRateDetails
                    }
                }
                .padding(.vertical, 6)
            } label: {
                Label("More details", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var expenseScheduleDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule")
                .font(.subheadline.weight(.semibold))

            timingPicker
            scheduleRepeatFields
        }
    }

    private var expenseBillDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bill total")
                .font(.subheadline.weight(.semibold))

            CurrencyInputField("Total due (optional)", text: $amountDue, currency: $dueCurrency)
        }
    }

    private var expenseReturnedMoneyDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Returned money")
                .font(.subheadline.weight(.semibold))

            ForEach(Array(inflows)) { movement in
                if let index = inflows.firstIndex(where: { $0.id == movement.id }) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Return \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            removeLineButton(
                                accessibilityLabel: "Remove returned money \(index + 1)"
                            ) {
                                inflows.remove(at: index)
                                if inflows.isEmpty { requestedChange = "" }
                            }
                        }

                        MovementLineEditor(
                            store: store,
                            line: $inflows[index],
                            amountPlaceholder: "Amount returned",
                            allowsArchivedAccount: allowsArchivedMovementAccounts
                        )
                    }
                    .padding(12)
                    .pocketGroupedSurface(cornerRadius: 14)
                }
            }

            Button {
                inflows.append(newReceivingMovementDraft)
            } label: {
                Label(
                    inflows.isEmpty ? "Add returned money" : "Add another receiving account",
                    systemImage: "arrow.down.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)

            if inflows.count == 1 {
                CurrencyInputField(
                    "Expected change (optional)",
                    text: $requestedChange,
                    currency: inflows[0].currency
                )
                Text("Enter how much change you expected. Pocket Ledger compares it with the returned money above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let preview = shortfallPreview {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.warning)
                }
            }

            Text("Returned money may go to a different account and currency than the payment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func removeLineButton(
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: .destructive, action: action) {
            Label("Remove", systemImage: "trash")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(Color.red.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.red)
        .frame(minHeight: 44)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var expenseAttachmentDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attachments")
                .font(.subheadline.weight(.semibold))

            TransactionAttachmentRows(
                attachments: attachments,
                onPreview: { previewAttachment = $0 },
                onReplace: { beginReplacingAttachment($0) },
                onDelete: { deleteAttachment($0) }
            )

            if attachments.isEmpty, let initialAttachmentFileName {
                Label(
                    initialAttachmentFileName,
                    systemImage: initialAttachmentContentType == "application/pdf" ? "doc.richtext" : "photo"
                )
                Text("This local file will be saved with the transaction.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section("Details") {
            if kind == .expense, !supportsPaymentCategories {
                if selectableCategories.isEmpty {
                    Text("No categories yet — this expense will be Uncategorized.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        selectedPaymentCategoryIndex = nil
                        isSelectingCategory = true
                    } label: {
                        LabeledContent("Category") {
                            HStack(spacing: 6) {
                                Text(selectedCategoryPath)
                                    .lineLimit(1)
                                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Search categories or browse the category hierarchy")
                }
            }

            TextField("What was this for?", text: $note, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    @ViewBuilder
    private var attachmentSection: some View {
        if !attachments.isEmpty {
            Section("Attachments") {
                TransactionAttachmentRows(
                    attachments: attachments,
                    onPreview: { previewAttachment = $0 },
                    onReplace: { beginReplacingAttachment($0) },
                    onDelete: { deleteAttachment($0) }
                )
                .disabled(replacingAttachmentID != nil)
                if replacingAttachmentID != nil {
                    Label("Reading replacement…", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
        } else if let initialAttachmentFileName {
            Section("Receipt attachment") {
                Label(initialAttachmentFileName, systemImage: initialAttachmentContentType == "application/pdf" ? "doc.richtext" : "photo")
                Text("This local file will be saved with the transaction after you tap \(saveButtonTitle.lowercased()).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allowsArchivedMovementAccounts: Bool {
        editingTransactionID != nil || editingScheduleID != nil || editingTemplateID != nil
    }

    private var isTemplateEditor: Bool {
        editingTemplateID != nil || isCreatingTemplate
    }

    private var monthlyScheduleDescription: String {
        if monthlyRule == .lastDayOfMonth {
            return "This runs on the last calendar day of each month."
        }
        return "This keeps day \(Calendar.current.component(.day, from: date)) when the month has that day."
    }

    @ViewBuilder
    private var outgoingMovementSection: some View {
        if kind != .income {
            Section {
                ForEach($outflows) { $line in
                    MovementLineEditor(
                        store: store,
                        line: $line,
                        amountPlaceholder: kind == .transfer ? "Amount sent" : "Amount leaving account",
                        allowsArchivedAccount: allowsArchivedMovementAccounts
                    )
                }
                .onDelete { outflows.remove(atOffsets: $0) }

                Button {
                    outflows.append(newMovementDraft)
                } label: {
                    Label("Add another account", systemImage: "plus.circle")
                }
            } header: {
                Text(kind == .transfer ? "From" : "Money leaving accounts")
            } footer: {
                Text(kind == .transfer
                     ? "Choose the account and amount sending the transfer."
                     : "Use one line for each currency or account used to pay.")
            }
        }
    }

    private var receivingMovementSection: some View {
        Section {
            if inflows.isEmpty {
                Button {
                    inflows.append(newMovementDraft)
                } label: {
                    Label(
                        kind == .expense ? "Add returned money" : "Add receiving account",
                        systemImage: "arrow.down.circle"
                    )
                }
            } else {
                ForEach($inflows) { $line in
                    MovementLineEditor(
                        store: store,
                        line: $line,
                        amountPlaceholder: kind == .transfer ? "Amount received" : "Amount entering account",
                        allowsArchivedAccount: allowsArchivedMovementAccounts
                    )
                }
                .onDelete { inflows.remove(atOffsets: $0) }

                Button {
                    inflows.append(newMovementDraft)
                } label: {
                    Label("Add another receiving account", systemImage: "plus.circle")
                }

                if kind == .expense && inflows.count == 1 {
                    CurrencyInputField(
                        "Expected change (optional)",
                        text: $requestedChange,
                        currency: inflows[0].currency
                    )
                    if let preview = shortfallPreview {
                        Text(preview)
                            .font(.footnote)
                            .foregroundStyle(PocketLedgerTheme.warning)
                    }
                }
            }
        } header: {
            Text(kind == .transfer
                 ? "To"
                 : kind == .expense ? "Change / money returned" : "Money entering accounts")
        } footer: {
            Text(kind == .transfer
                 ? "The amount is filled from the sending amount when possible. You can edit it for a specific transfer."
                 : kind == .expense
                    ? "Returned money may go to a different account and currency than the payment."
                    : "Choose the account and currency receiving the money.")
        }
    }

    @ViewBuilder
    private var exchangeRateSection: some View {
        if selectedCurrencies.count > 1 {
            Section("Exchange rate") {
                LabeledContent("Applied rate") {
                    Text(appliedExchangeRate?.summary ?? "Rate required")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(appliedExchangeRate == nil
                            ? PocketLedgerTheme.warning
                            : PocketLedgerTheme.textPrimary)
                        .multilineTextAlignment(.trailing)
                }

                Toggle(
                    kind == .transfer ? "Override for this transaction" : "Use a custom rate",
                    isOn: $useCustomRate
                )

                if !useCustomRate {
                    Text("The rate is calculated from the entered amounts, or uses the saved pair rate until both amounts are entered.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if useCustomRate {
                    Picker("Base", selection: $rateBase) {
                        ForEach(selectedCurrencies) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                    Picker("Quote", selection: $rateQuote) {
                        ForEach(selectedCurrencies) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                    TextField("Quote units per base unit", text: $rateText)
                        .keyboardType(.decimalPad)

                    if let savedRate {
                        Button {
                            rateText = NSDecimalNumber(decimal: savedRate.quoteUnitsPerBaseUnit).stringValue
                        } label: {
                            Label("Use saved rate: \(savedRate.summary)", systemImage: "arrow.clockwise")
                        }
                    }

                    Text("Enter how many \(rateQuote.rawValue) equal 1 \(rateBase.rawValue).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exchangeRateDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exchange rate")
                .font(.subheadline.weight(.semibold))

            LabeledContent("Applied rate") {
                Text(appliedExchangeRate?.summary ?? "Rate required")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appliedExchangeRate == nil
                        ? PocketLedgerTheme.warning
                        : PocketLedgerTheme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }

            Toggle("Use a custom rate", isOn: $useCustomRate)

            if !useCustomRate {
                Text("The rate is calculated from the entered amounts, or uses the saved pair rate until both amounts are entered.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if useCustomRate {
                Picker("Base", selection: $rateBase) {
                    ForEach(selectedCurrencies) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                Picker("Quote", selection: $rateQuote) {
                    ForEach(selectedCurrencies) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                TextField("Quote units per base unit", text: $rateText)
                    .keyboardType(.decimalPad)

                if let savedRate {
                    Button {
                        rateText = NSDecimalNumber(decimal: savedRate.quoteUnitsPerBaseUnit).stringValue
                    } label: {
                        Label("Use saved rate: \(savedRate.summary)", systemImage: "arrow.clockwise")
                    }
                }

                Text("Enter how many \(rateQuote.rawValue) equal 1 \(rateBase.rawValue).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var completedOneTimeSchedule: Bool {
        isEditingScheduledTransaction
            && editingScheduleLastRunDate != nil
            && scheduleFrequency == .once
            && (editingScheduleNextRunDate.map { Calendar.current.isDate(date, inSameDayAs: $0) } ?? false)
    }

    private var navigationTitle: String {
        if isTemplateEditor {
            return editingTemplateID == nil ? "New template" : "Edit template"
        }
        if isEditingScheduledTransaction {
            return "Edit schedule"
        }
        if editingTransactionID != nil {
            return "Edit transaction"
        }
        return timing == .scheduled ? "Schedule transaction" : "New transaction"
    }

    private var saveButtonTitle: String {
        if isTemplateEditor {
            return "Save template"
        }
        if timing == .scheduled {
            return isEditingScheduledTransaction ? "Update" : "Schedule"
        }
        return editingTransactionID == nil ? "Save" : "Update"
    }

    private var attachments: [LedgerAttachment] {
        attachmentIDs.filter { !attachmentIDsPendingDeletion.contains($0) }.compactMap { id in
            store.data.attachments.first(where: { $0.id == id })
        }
    }

    private var selectedCategoryPath: String {
        categoryID.map { store.categoryPath(for: $0) } ?? "Uncategorized"
    }

    private var supportsPaymentCategories: Bool {
        !isTemplateEditor && kind == .expense && timing == .now
    }

    private var categorySelectionBinding: Binding<UUID?> {
        Binding(
            get: {
                if let index = selectedPaymentCategoryIndex,
                   outflows.indices.contains(index) {
                    return displayedPaymentCategoryID(at: index)
                }
                return categoryID
            },
            set: { selectedCategoryID in
                if let index = selectedPaymentCategoryIndex,
                   outflows.indices.contains(index) {
                    outflows[index].categoryID = selectedCategoryID
                    outflows[index].hasCategoryAssignment = true
                    if index == 0 { categoryID = selectedCategoryID }
                } else {
                    categoryID = selectedCategoryID
                }
            }
        )
    }

    private func paymentCategorySelector(at index: Int) -> some View {
        Button {
            selectedPaymentCategoryIndex = index
            isSelectingCategory = true
        } label: {
            LabeledContent("Category") {
                HStack(spacing: 6) {
                    Text(displayedPaymentCategoryID(at: index).map { store.categoryPath(for: $0) } ?? "Uncategorized")
                        .lineLimit(1)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category for payment \(index + 1)")
        .accessibilityHint("Search categories or browse the category hierarchy")
    }

    private func displayedPaymentCategoryID(at index: Int) -> UUID? {
        guard outflows.indices.contains(index), outflows[index].hasCategoryAssignment else {
            return categoryID
        }
        return outflows[index].categoryID
    }

    private func beginReplacingAttachment(_ attachment: LedgerAttachment) {
        replacingAttachmentID = attachment.id
        isShowingAttachmentImporter = true
    }

    private var selectableCategories: [LedgerCategory] {
        var categories = store.activeCategories
        let selectedIDs = [categoryID] + outflows.map(\.categoryID)
        for id in selectedIDs.compactMap({ $0 }) {
            if let category = store.ledgerIndex.categoriesByID[id],
               !categories.contains(where: { $0.id == category.id }) {
                categories.append(category)
            }
        }
        return categories
    }

    private func replaceAttachment(_ result: Result<[URL], Error>) {
        guard let attachmentID = replacingAttachmentID else { return }
        do {
            guard let url = try result.get().first else {
                replacingAttachmentID = nil
                return
            }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            Task {
                defer {
                    if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                    replacingAttachmentID = nil
                }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    attachmentReplacements[attachmentID] = PendingAttachmentReplacement(
                        data: data,
                        fileName: url.lastPathComponent,
                        contentType: contentType
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            replacingAttachmentID = nil
            errorMessage = error.localizedDescription
        }
    }

    private var newMovementDraft: MovementDraft {
        let account = store.activeAccounts.first
        return MovementDraft(
            accountID: account?.id ?? UUID(),
            currency: account?.currency ?? .usd,
            amount: ""
        )
    }

    private var newSplitPaymentDraft: MovementDraft {
        let usedAccountIDs = Set(outflows.map(\.accountID))
        let account = store.activeAccounts.first(where: { !usedAccountIDs.contains($0.id) })
            ?? store.activeAccounts.first
        return MovementDraft(
            accountID: account?.id ?? UUID(),
            currency: account?.currency ?? .usd,
            amount: "",
            categoryID: outflows.isEmpty ? categoryID : displayedPaymentCategoryID(at: 0),
            hasCategoryAssignment: supportsPaymentCategories
        )
    }

    private var newReceivingMovementDraft: MovementDraft {
        let sourceAccountIDs = Set(outflows.map(\.accountID))
        let account = store.activeAccounts.first(where: { !sourceAccountIDs.contains($0.id) })
            ?? store.activeAccounts.first
        return MovementDraft(
            accountID: account?.id ?? UUID(),
            currency: account?.currency ?? .usd,
            amount: ""
        )
    }

    private static func inputText(for money: Money) -> String {
        money.currency.formattedInput(minorUnits: money.minorUnits)
    }

    private var selectedCurrencies: [LedgerCurrency] {
        let drafts = (kind == .income ? [] : outflows) + inflows
        let currencies = Set(
            drafts.flatMap { draft in
                [
                    draft.currency,
                    store.account(with: draft.accountID)?.currency
                ].compactMap { $0 }
            }
        )
        return LedgerCurrency.allCases.filter { currencies.contains($0) }
    }

    private var savedRate: ExchangeRate? {
        store.exchangeRate(base: rateBase, quote: rateQuote)
    }

    private var rateCurrencyPair: (base: LedgerCurrency, quote: LedgerCurrency)? {
        if kind == .transfer,
           let sourceCurrency = outflows.first?.currency,
           let destinationCurrency = inflows.first?.currency,
           sourceCurrency != destinationCurrency {
            return (base: sourceCurrency, quote: destinationCurrency)
        }

        let drafts = (kind == .income ? [] : outflows) + inflows
        for draft in drafts {
            guard let accountCurrency = store.account(with: draft.accountID)?.currency,
                  accountCurrency != draft.currency else {
                continue
            }
            return (base: accountCurrency, quote: draft.currency)
        }

        let currencies = selectedCurrencies
        if currencies.count > 1 {
            return (base: currencies[0], quote: currencies[1])
        }
        return nil
    }

    private var parsedRateValue: Decimal? {
        Decimal(
            string: rateText.replacingOccurrences(of: ",", with: ""),
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private var customExchangeRate: ExchangeRate? {
        guard rateBase != rateQuote,
              selectedCurrencies.contains(rateBase),
              selectedCurrencies.contains(rateQuote),
              let rate = parsedRateValue,
              rate > 0 else {
            return nil
        }
        return ExchangeRate(
            baseCurrency: rateBase,
            quoteCurrency: rateQuote,
            quoteUnitsPerBaseUnit: rate
        )
    }

    private var calculatedExchangeRate: ExchangeRate? {
        guard let pair = rateCurrencyPair,
              let parsedOutflows,
              let parsedInflows else {
            return nil
        }

        let parsedMovements = parsedOutflows + parsedInflows
        let sourceUnits = parsedMovements
            .filter { $0.money.currency == pair.base }
            .reduce(Decimal.zero) { total, movement in
                total + Decimal(movement.money.minorUnits) / Decimal(pair.base.minorUnitScale)
            }
        let destinationUnits = parsedMovements
            .filter { $0.money.currency == pair.quote }
            .reduce(Decimal.zero) { total, movement in
                total + Decimal(movement.money.minorUnits) / Decimal(pair.quote.minorUnitScale)
            }
        guard sourceUnits > 0, destinationUnits > 0 else { return nil }

        return ExchangeRate(
            baseCurrency: pair.base,
            quoteCurrency: pair.quote,
            quoteUnitsPerBaseUnit: destinationUnits / sourceUnits
        )
    }

    private var appliedExchangeRate: ExchangeRate? {
        guard let pair = rateCurrencyPair else { return nil }

        if useCustomRate {
            guard let customExchangeRate,
                  let rate = directedRate(
                      customExchangeRate.quoteUnitsPerBaseUnit,
                      from: customExchangeRate.baseCurrency,
                      to: customExchangeRate.quoteCurrency,
                      base: pair.base,
                      quote: pair.quote
                  ) else {
                return nil
            }
            return ExchangeRate(
                baseCurrency: pair.base,
                quoteCurrency: pair.quote,
                quoteUnitsPerBaseUnit: rate
            )
        }

        return calculatedExchangeRate
            ?? store.exchangeRate(base: pair.base, quote: pair.quote)
    }

    private func directedRate(
        _ value: Decimal,
        from sourceBase: LedgerCurrency,
        to sourceQuote: LedgerCurrency,
        base targetBase: LedgerCurrency,
        quote targetQuote: LedgerCurrency
    ) -> Decimal? {
        guard value > 0, sourceBase != sourceQuote, targetBase != targetQuote else {
            return nil
        }
        if sourceBase == targetBase && sourceQuote == targetQuote {
            return value
        }
        if sourceBase == targetQuote && sourceQuote == targetBase {
            return Decimal(1) / value
        }
        return nil
    }

    private static func money(
        units: Decimal,
        currency: LedgerCurrency
    ) -> Money? {
        guard units > 0 else { return nil }
        var scaled = units * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let minorUnits = NSDecimalNumber(decimal: rounded).int64Value
        guard minorUnits > 0 else { return nil }
        return Money(currency: currency, minorUnits: minorUnits)
    }

    private func synchronizeRatePair() {
        let currencies = selectedCurrencies
        guard currencies.count > 1,
              !currencies.contains(rateBase) || !currencies.contains(rateQuote) || rateBase == rateQuote else {
            return
        }

        rateBase = currencies[0]
        rateQuote = currencies[1]
        if let savedRate {
            rateText = NSDecimalNumber(decimal: savedRate.quoteUnitsPerBaseUnit).stringValue
        }
    }

    private func handleKindChange(_ newKind: TransactionKind) {
        if newKind == .transfer && inflows.isEmpty {
            inflows.append(newReceivingMovementDraft)
        }
        if newKind != .transfer {
            automaticTransferDestinationAmount = nil
        }
        synchronizeRatePair()
        synchronizeAutomaticTransferAmount()
    }

    private func prepareCustomRate() {
        guard let pair = rateCurrencyPair else { return }
        rateBase = pair.base
        rateQuote = pair.quote
        if let rate = calculatedExchangeRate
            ?? store.exchangeRate(base: pair.base, quote: pair.quote) {
            rateText = NSDecimalNumber(decimal: rate.quoteUnitsPerBaseUnit).stringValue
        }
    }

    private func synchronizeAutomaticTransferAmount() {
        guard kind == .transfer else { return }

        guard outflows.count == 1,
              inflows.count == 1 else {
            clearAutomaticTransferAmount()
            return
        }

        guard let sourceAccount = store.account(with: outflows[0].accountID),
              let destinationAccount = store.account(with: inflows[0].accountID) else {
            clearAutomaticTransferAmount()
            return
        }

        let currentDestinationAmount = inflows[0].amount
        let canUpdate = currentDestinationAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || currentDestinationAmount == automaticTransferDestinationAmount
        guard canUpdate,
              let sourceMoney = Money.parse(outflows[0].amount, currency: outflows[0].currency),
              sourceMoney.minorUnits > 0 else {
            clearAutomaticTransferAmount()
            return
        }

        let destinationMoney: Money?
        if outflows[0].currency == inflows[0].currency {
            destinationMoney = sourceMoney
        } else {
            guard let rate = automaticTransferRate else {
                clearAutomaticTransferAmount()
                return
            }
            let sourceUnits = Decimal(sourceMoney.minorUnits) / Decimal(sourceMoney.currency.minorUnitScale)
            destinationMoney = Self.money(
                units: sourceUnits * rate,
                currency: inflows[0].currency
            )
        }

        guard let destinationMoney else {
            clearAutomaticTransferAmount()
            return
        }

        let amount = Self.inputText(for: destinationMoney)
        automaticTransferDestinationAmount = amount
        inflows[0].amount = amount
    }

    private func clearAutomaticTransferAmount() {
        if let automaticTransferDestinationAmount,
           inflows.count == 1,
           inflows[0].amount == automaticTransferDestinationAmount {
            inflows[0].amount = ""
        }
        automaticTransferDestinationAmount = nil
    }

    private var automaticTransferRate: Decimal? {
        guard let pair = rateCurrencyPair else { return nil }
        if useCustomRate {
            guard let customExchangeRate else { return nil }
            return directedRate(
                customExchangeRate.quoteUnitsPerBaseUnit,
                from: customExchangeRate.baseCurrency,
                to: customExchangeRate.quoteCurrency,
                base: pair.base,
                quote: pair.quote
            )
        }
        return store.exchangeRate(base: pair.base, quote: pair.quote)?.quoteUnitsPerBaseUnit
    }

    private var parsedOutflows: [MoneyMovement]? {
        guard kind != .income else { return [] }
        return parseMovements(outflows, assignsPaymentCategories: supportsPaymentCategories)
    }

    private var parsedInflows: [MoneyMovement]? {
        parseMovements(inflows)
    }

    private var saveValidationMessage: String? {
        if isTemplateEditor,
           templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name for this template."
        }
        guard let parsedOutflows, let parsedInflows else {
            return "Enter a valid positive amount for every account line."
        }

        switch kind {
        case .expense:
            guard !parsedOutflows.isEmpty else { return "Add a payment amount to save this expense." }
        case .income:
            guard !parsedInflows.isEmpty else { return "Add an amount and receiving account to save this income." }
        case .transfer:
            guard !parsedOutflows.isEmpty, !parsedInflows.isEmpty else {
                return "Add valid sending and receiving amounts to save this transfer."
            }
        }

        if kind == .expense,
           inflows.count == 1,
           !requestedChange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard parsedInflows.count == 1,
                  let requested = Money.parse(requestedChange, currency: inflows[0].currency),
                  requested.minorUnits >= 0 else {
                 return "Enter a valid nonnegative amount for expected change."
            }
        }

        if !amountDue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard kind == .expense,
                  let due = Money.parse(amountDue, currency: dueCurrency),
                  due.minorUnits > 0 else {
                 return "Enter a bill total greater than zero."
            }
        }

        if selectedCurrencies.count > 1 {
            guard appliedExchangeRate != nil else { return "Enter a valid exchange rate for these currencies." }
        }

        return nil
    }

    private var canSave: Bool {
        saveValidationMessage == nil && replacingAttachmentID == nil
    }

    private var editorSnapshot: TransactionEditorSnapshot {
        TransactionEditorSnapshot(
            templateName: templateName,
            note: note,
            date: date,
            kind: kind,
            timing: timing,
            scheduleFrequency: scheduleFrequency,
            monthlyRule: monthlyRule,
            scheduleEnabled: scheduleEnabled,
            categoryID: categoryID,
            dueCurrency: dueCurrency,
            amountDue: amountDue,
            outflows: outflows,
            inflows: inflows,
            requestedChange: requestedChange,
            useCustomRate: useCustomRate,
            rateBase: rateBase,
            rateQuote: rateQuote,
            rateText: rateText,
            attachmentIDs: attachmentIDs,
            deletedAttachmentIDs: attachmentIDsPendingDeletion,
            attachmentReplacements: attachmentReplacements
        )
    }

    private var hasUnsavedChanges: Bool {
        guard let originalEditorSnapshot else { return false }
        return editorSnapshot != originalEditorSnapshot
    }

    private func cancel() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var shortfallPreview: String? {
        guard inflows.count == 1,
              let requested = Money.parse(requestedChange, currency: inflows[0].currency),
              let actual = Money.parse(inflows[0].amount, currency: inflows[0].currency) else {
            return nil
        }

        let difference = requested.minorUnits - actual.minorUnits
        if difference > 0 {
            return "Received \(Money(currency: inflows[0].currency, minorUnits: actual.minorUnits).formatted) — \(Money(currency: inflows[0].currency, minorUnits: difference).formatted) less than expected."
        }
        if difference < 0 {
            return "Received \(Money(currency: inflows[0].currency, minorUnits: -difference).formatted) more than expected."
        }
        return "Actual and expected change match."
    }

    private func parseMovements(
        _ drafts: [MovementDraft],
        assignsPaymentCategories: Bool = false
    ) -> [MoneyMovement]? {
        let hasPaymentCategories = assignsPaymentCategories
            && drafts.contains(where: \.hasCategoryAssignment)
        let movements = drafts.compactMap { draft -> MoneyMovement? in
            guard let account = store.account(with: draft.accountID),
                  let money = Money.parse(draft.amount, currency: draft.currency),
                  money.minorUnits > 0 else {
                return nil
            }
            return MoneyMovement(
                id: draft.id,
                accountID: account.id,
                money: money,
                categoryID: hasPaymentCategories ? draft.categoryID : nil,
                hasCategoryAssignment: hasPaymentCategories
            )
        }
        return movements.count == drafts.count ? movements : nil
    }

    private func save() {
        guard let parsedOutflows, let parsedInflows else {
            errorMessage = "Enter a valid amount for every account line."
            return
        }

        var exchangeRate: ExchangeRate?
        if selectedCurrencies.count > 1 {
            guard let appliedExchangeRate else {
                errorMessage = kind == .transfer
                    ? "Enter both transfer amounts or set a positive rate override."
                    : "Set a positive exchange rate for the different movement and account currencies."
                return
            }
            exchangeRate = appliedExchangeRate
        }

        var changeAdjustment: ChangeAdjustment?
        if kind == .expense,
           !requestedChange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           parsedInflows.count == 1,
           let requested = Money.parse(requestedChange, currency: inflows[0].currency) {
            changeAdjustment = ChangeAdjustment(requested: requested, actual: parsedInflows[0].money)
        }

        var parsedAmountDue: Money?
        if !amountDue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard kind == .expense,
                  let value = Money.parse(amountDue, currency: dueCurrency),
                  value.minorUnits > 0 else {
                errorMessage = "Enter a valid bill total."
                return
            }
            parsedAmountDue = value
        }

        guard !(timing == .scheduled && initialAttachmentData != nil) else {
            errorMessage = "Receipt attachments can only be saved with an immediate transaction. Switch When back to Now to keep this receipt."
            return
        }

        var createdAttachments: [LedgerAttachment] = []
        var savedAttachmentIDs = attachmentIDs.filter { !attachmentIDsPendingDeletion.contains($0) }
        if timing != .scheduled,
           editingTransactionID == nil,
           let initialAttachmentData,
           let initialAttachmentFileName,
           let initialAttachmentContentType {
            guard let attachment = store.addAttachment(
                data: initialAttachmentData,
                fileName: initialAttachmentFileName,
                contentType: initialAttachmentContentType,
                receiptItems: initialReceiptItems,
                extractedTotal: parsedAmountDue
            ) else {
                errorMessage = store.lastActionStatus ?? "The receipt could not be attached."
                return
            }
            createdAttachments.append(attachment)
            savedAttachmentIDs.append(attachment.id)
        }

        for (replacedID, replacement) in attachmentReplacements {
            guard let idIndex = savedAttachmentIDs.firstIndex(of: replacedID),
                  let attachment = store.addAttachment(
                    data: replacement.data,
                    fileName: replacement.fileName,
                    contentType: replacement.contentType
                  ) else {
                createdAttachments.forEach { _ = store.deleteAttachment(id: $0.id) }
                errorMessage = store.lastActionStatus ?? "The receipt replacement could not be saved."
                return
            }
            createdAttachments.append(attachment)
            savedAttachmentIDs[idIndex] = attachment.id
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPaymentCategories = supportsPaymentCategories
            && parsedOutflows.contains(where: \.hasCategoryAssignment)
        let savedCategoryAllocations = kind == .expense && !hasPaymentCategories
            ? editingTransactionID.flatMap { id in
                store.data.transactions.first(where: { $0.id == id })?.categoryAllocations
            }
            : nil
        let savedCategoryID = kind == .expense
            ? (hasPaymentCategories ? parsedOutflows.first?.categoryID : categoryID)
            : nil
        categoryID = savedCategoryID
        let transaction = LedgerTransaction(
            id: editingTransactionID ?? UUID(),
            date: date,
            note: trimmedNote.isEmpty ? kind.displayName : trimmedNote,
            kind: kind,
            categoryID: savedCategoryID,
            categoryAllocations: savedCategoryAllocations,
            amountDue: parsedAmountDue,
            outflows: parsedOutflows,
            inflows: parsedInflows,
            exchangeRate: exchangeRate,
            changeAdjustment: changeAdjustment,
            attachmentIDs: savedAttachmentIDs
        )

        if isTemplateEditor {
            let saved: Bool
            if let editingTemplateID {
                guard var template = store.data.templates.first(where: { $0.id == editingTemplateID }) else {
                    errorMessage = "Template not found."
                    return
                }
                template.name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                template.note = transaction.note
                template.kind = transaction.kind
                template.categoryID = transaction.categoryID
                template.amountDue = transaction.amountDue
                template.outflows = transaction.outflows
                template.inflows = transaction.inflows
                template.exchangeRate = transaction.exchangeRate
                template.changeAdjustment = transaction.changeAdjustment
                saved = store.updateTemplate(template)
            } else {
                saved = store.addTemplate(
                    LedgerTemplate(
                        name: templateName.trimmingCharacters(in: .whitespacesAndNewlines),
                        transaction: transaction
                    )
                )
            }
            guard saved else {
                errorMessage = store.lastActionStatus ?? "The template could not be saved."
                return
            }
        } else if timing == .scheduled {
            let dateChanged = editingScheduleNextRunDate.map {
                !Calendar.current.isDate(date, inSameDayAs: $0)
            } ?? false
            let frequencyChanged = editingScheduleFrequency.map { $0 != scheduleFrequency } ?? false
            let recurrenceDay = dateChanged || editingScheduleRecurrenceDay == nil
                ? Calendar.current.component(.day, from: date)
                : editingScheduleRecurrenceDay!
            let lastRunDate = dateChanged || frequencyChanged ? nil : editingScheduleLastRunDate
            let enabled = lastRunDate != nil && scheduleFrequency == .once
                ? false
                : scheduleEnabled
            let scheduledTransaction = ScheduledTransaction(
                id: editingScheduleID ?? UUID(),
                nextRunDate: date,
                frequency: scheduleFrequency,
                monthlyRule: monthlyRule,
                recurrenceDay: recurrenceDay,
                isEnabled: enabled,
                reminderTiming: editingScheduleReminderTiming,
                lastRunDate: lastRunDate,
                note: transaction.note,
                kind: transaction.kind,
                categoryID: transaction.categoryID,
                amountDue: transaction.amountDue,
                outflows: transaction.outflows,
                inflows: transaction.inflows,
                exchangeRate: transaction.exchangeRate,
                changeAdjustment: transaction.changeAdjustment
            )

            let saved = editingScheduleID != nil
                ? store.updateScheduledTransaction(scheduledTransaction)
                : store.addScheduledTransaction(scheduledTransaction)
            guard saved else {
                if let feature = store.proAccessRequired {
                    proAccess.requestUpgrade(for: feature)
                    isShowingProUpgrade = true
                } else {
                    errorMessage = store.lastActionStatus ?? "The schedule could not be saved."
                }
                return
            }
        } else {
            let saved: Bool
            if editingTransactionID == nil {
                saved = store.addTransaction(transaction)
            } else {
                saved = store.updateTransaction(transaction)
            }
            guard saved else {
                createdAttachments.forEach { _ = store.deleteAttachment(id: $0.id) }
                errorMessage = store.lastActionStatus ?? "The transaction could not be saved."
                return
            }
        }

        let replacedAttachmentIDs = Set(attachmentReplacements.keys)
        for id in attachmentIDsPendingDeletion.union(replacedAttachmentIDs) {
            _ = store.deleteAttachment(id: id)
        }

        if !isTemplateEditor {
            if let accountID = (parsedOutflows.first ?? parsedInflows.first)?.accountID {
                UserDefaults.standard.set(accountID.uuidString, forKey: Self.lastAccountKey)
            }
            if let categoryID, kind == .expense {
                UserDefaults.standard.set(categoryID.uuidString, forKey: Self.lastCategoryKey)
            }
        }
        saveFeedbackTrigger += 1
        dismiss()
    }

    private func deleteAttachment(_ attachment: LedgerAttachment) {
        attachmentIDsPendingDeletion.insert(attachment.id)
        attachmentReplacements.removeValue(forKey: attachment.id)
    }
}
