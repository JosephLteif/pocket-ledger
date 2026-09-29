import Foundation
import SwiftUI

private enum LoanListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case lent = "Lent"
    case borrowed = "Borrowed"
    case dueSoon = "Due soon"
    case overdue = "Overdue"
    case settled = "Settled"

    var id: String { rawValue }
}

@MainActor
struct LoansView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @State private var filter: LoanListFilter = .all
    @State private var isPresentingLoanEditor = false
    @State private var notificationMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    var body: some View {
        List {
            overviewSection

            if !store.legacyLoanAccountsNeedingSetup.isEmpty {
                Section("Set up existing loan accounts") {
                    ForEach(store.legacyLoanAccountsNeedingSetup) { account in
                        NavigationLink {
                            LegacyLoanConversionView(store: store, account: account)
                        } label: {
                            HStack(spacing: 12) {
                                PocketIcon(
                                    systemImage: "arrow.triangle.2.circlepath",
                                    tint: PocketLedgerTheme.warning,
                                    size: 36
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Review current balance and convert to a managed loan")
                                        .font(.caption)
                                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                                }
                                Spacer(minLength: 8)
                                ProtectedAmountText(
                                    value: store.balance(for: account).formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.caption.weight(.semibold).monospacedDigit())
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LoanListFilter.allCases) { item in
                            Button {
                                filter = item
                            } label: {
                                Text(item.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(filter == item ? .white : PocketLedgerTheme.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        filter == item ? PocketLedgerTheme.accent : PocketLedgerTheme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                if filteredLoans.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "arrow.left.arrow.right.circle",
                        description: Text(emptyDescription)
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredLoans) { loan in
                        NavigationLink {
                            LoanDetailView(store: store, loanID: loan.id)
                        } label: {
                            LoanRow(
                                loan: loan,
                                status: status(for: loan),
                                areBalancesRevealed: areBalancesRevealed
                            )
                        }
                        .listRowBackground(PocketLedgerTheme.surface)
                    }
                }
            } header: {
                Text("Loans")
            }

            if activeLoans.contains(where: { $0.dueDate != nil }) {
                Section {
                    Button {
                        Task {
                            notificationMessage = await NotificationService.requestLoanNotifications(
                                loans: store.data.loans
                            )
                        }
                    } label: {
                        Label("Enable loan reminders", systemImage: "bell.badge")
                    }
                } footer: {
                    Text("Reminders use your saved timing preference. Due dates stay visible here if notifications are unavailable.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .pocketScreen()
        .navigationTitle("Loans")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingLoanEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add loan")
                }
            }
        }
        .sheet(isPresented: $isPresentingLoanEditor) {
            LoanEditor(store: store)
        }
        .alert("Loan reminders", isPresented: notificationMessagePresented) {
            Button("OK") { notificationMessage = nil }
        } message: {
            Text(notificationMessage ?? "")
        }
    }

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LedgerCurrency.allCases) { currency in
                    let lent = store.assetBalance(for: currency).minorUnits
                        - store.availableBalance(for: currency).minorUnits
                    let borrowed = store.liabilityBalance(for: currency).minorUnits
                        - store.loanBalance(for: currency).minorUnits
                    if lent != 0 || borrowed != 0 {
                        HStack(spacing: 10) {
                            Text(currency.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("Lent")
                                    .font(.caption2)
                                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                                ProtectedAmountText(
                                    value: Money(currency: currency, minorUnits: lent).formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(PocketLedgerTheme.income)
                            }
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("Borrowed")
                                    .font(.caption2)
                                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                                ProtectedAmountText(
                                    value: Money(currency: currency, minorUnits: borrowed).formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(PocketLedgerTheme.warning)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    loanCountBadge(title: "Due soon", count: dueSoonLoans.count, tint: PocketLedgerTheme.accent)
                    loanCountBadge(title: "Overdue", count: overdueLoans.count, tint: PocketLedgerTheme.warning)
                    loanCountBadge(title: "Settled", count: settledLoans.count, tint: PocketLedgerTheme.textSecondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Loan overview")
        }
    }

    private func loanCountBadge(title: String, count: Int, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.headline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(PocketLedgerTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private var activeLoans: [Loan] { store.data.loans.filter { !$0.isSettled } }
    private var settledLoans: [Loan] { store.data.loans.filter(\.isSettled) }
    private var overdueLoans: [Loan] { activeLoans.filter { status(for: $0) == "Overdue" } }
    private var dueSoonLoans: [Loan] { activeLoans.filter { status(for: $0) == "Due soon" } }

    private var filteredLoans: [Loan] {
        let filtered = store.data.loans.filter { loan in
            switch filter {
            case .all: true
            case .lent: loan.direction == .lent && !loan.isSettled
            case .borrowed: loan.direction == .borrowed && !loan.isSettled
            case .dueSoon: status(for: loan) == "Due soon"
            case .overdue: status(for: loan) == "Overdue"
            case .settled: loan.isSettled
            }
        }
        return filtered.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?) where left != right: left < right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.counterparty.localizedCaseInsensitiveCompare(rhs.counterparty) == .orderedAscending
            }
        }
    }

    private func status(for loan: Loan) -> String {
        guard !loan.isSettled, let dueDate = loan.dueDate else {
            return loan.isSettled ? "Settled" : "Active"
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        if dueDate < today { return "Overdue" }
        if let soonLimit = calendar.date(byAdding: .day, value: 7, to: today), dueDate < soonLimit {
            return "Due soon"
        }
        return "Active"
    }

    private var emptyTitle: String {
        filter == .all ? "No loans yet" : "No \(filter.rawValue.lowercased()) loans"
    }

    private var emptyDescription: String {
        filter == .all
            ? "Add a loan you gave or received to track its balance and due date."
            : "Loans matching this view will appear here."
    }

    private var notificationMessagePresented: Binding<Bool> {
        Binding(get: { notificationMessage != nil }, set: { if !$0 { notificationMessage = nil } })
    }
}

@MainActor
private struct LoanRow: View {
    let loan: Loan
    let status: String
    let areBalancesRevealed: Bool

    var body: some View {
        HStack(spacing: 12) {
            PocketIcon(
                systemImage: loan.direction == .lent ? "arrow.up.right" : "arrow.down.left",
                tint: loan.isSettled ? PocketLedgerTheme.textTertiary : PocketLedgerTheme.accent,
                size: 36
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(loan.counterparty)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 5) {
                    Text(loan.direction.displayName)
                    Text("·")
                    Text(status)
                        .foregroundStyle(status == "Overdue" ? PocketLedgerTheme.warning : PocketLedgerTheme.textSecondary)
                }
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
                if let dueDate = loan.dueDate, !loan.isSettled {
                    Text("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            ProtectedAmountText(value: loan.outstandingAmount.formatted, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(loan.isSettled ? PocketLedgerTheme.textSecondary : PocketLedgerTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct LegacyLoanConversionView: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [LegacyLoanDraft]
    @State private var errorMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(store: LedgerStore, account: Account) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account
        let current = store.balance(for: account)
        _drafts = State(initialValue: [LegacyLoanDraft(
            counterparty: account.name,
            amountText: account.currency.formattedInput(minorUnits: max(0, current.minorUnits))
        )])
    }

    var body: some View {
        Form {
            Section("Current account") {
                LabeledContent("Account", value: account.name)
                LabeledContent("Currency", value: account.currency.rawValue)
                LabeledContent("Current balance") {
                    ProtectedAmountText(
                        value: currentBalance.formatted,
                        isRevealed: areBalancesRevealed
                    )
                }
                Text("Convert this account balance into managed loans and keep its existing transactions as history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if currentBalance.minorUnits == 0 {
                    Text("This loan account has no outstanding balance. Converting it archives the account and keeps its transaction history available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if currentBalance.minorUnits < 0 {
                    Text("This account has a negative balance. Reconcile it before converting it to a managed loan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Direction", selection: $draft.direction) {
                                ForEach(LoanDirection.allCases) { direction in
                                    Text(direction.displayName).tag(direction)
                                }
                            }
                            TextField(draft.direction.counterpartyLabel, text: $draft.counterparty)
                            CurrencyInputField("Amount", text: $draft.amountText, currency: account.currency)
                            Toggle("Add due date", isOn: $draft.hasDueDate)
                            if draft.hasDueDate {
                                DatePicker("Due date", selection: $draft.dueDate, displayedComponents: .date)
                            }
                            if drafts.count > 1 {
                                Button("Remove loan", systemImage: "minus.circle", role: .destructive) {
                                    drafts.removeAll { $0.id == draft.id }
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Split into another loan", systemImage: "plus.circle") {
                        drafts.append(LegacyLoanDraft(
                            counterparty: account.name,
                            amountText: "",
                            direction: .borrowed,
                            hasDueDate: false,
                            dueDate: .now
                        ))
                    }
                }
            } header: {
                Text("Review loans")
            } footer: {
                Text("Each loan defaults to borrowed. Choose a direction for each one; the amounts must add up to the account’s current balance.")
            }

            Section {
                LabeledContent("Loan total") {
                    ProtectedAmountText(value: draftTotal.formatted, isRevealed: areBalancesRevealed)
                }
                LabeledContent("Difference") {
                    ProtectedAmountText(
                        value: Money(currency: account.currency, minorUnits: currentBalance.minorUnits - draftTotal.minorUnits).formatted,
                        isRevealed: areBalancesRevealed
                    )
                }
            }
        }
        .pocketListSurface()
        .navigationTitle("Convert loan account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Convert", action: convert)
                    .disabled(!canConvert)
            }
        }
        .errorMessageAlert(title: "Loan account not converted", message: $errorMessage)
    }

    private var currentBalance: Money { store.balance(for: account) }

    private var parsedAmounts: [Money]? {
        let amounts = drafts.compactMap { Money.parse($0.amountText, currency: account.currency) }
        return amounts.count == drafts.count ? amounts : nil
    }

    private var draftTotal: Money {
        Money(currency: account.currency, minorUnits: parsedAmounts?.reduce(Int64.zero) { $0 + $1.minorUnits } ?? 0)
    }

    private var canConvert: Bool {
        if currentBalance.minorUnits == 0 { return true }
        guard currentBalance.minorUnits > 0,
              let amounts = parsedAmounts,
              amounts.allSatisfy({ $0.minorUnits > 0 }) else { return false }
        return amounts.reduce(Int64.zero) { $0 + $1.minorUnits } == currentBalance.minorUnits
            && drafts.allSatisfy { !$0.counterparty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func convert() {
        let loans = currentBalance.minorUnits == 0 ? [] : drafts.compactMap { draft -> Loan? in
            guard let amount = Money.parse(draft.amountText, currency: account.currency) else { return nil }
            return Loan(
                counterparty: draft.counterparty.trimmingCharacters(in: .whitespacesAndNewlines),
                direction: draft.direction,
                currency: account.currency,
                startingAmount: amount,
                startedAt: .now,
                dueDate: draft.hasDueDate ? draft.dueDate : nil,
                legacyAccountID: account.id
            )
        }
        guard store.convertLegacyLoanAccount(accountID: account.id, into: loans) else {
            errorMessage = store.lastActionStatus ?? "Check that the loan amounts match the account balance."
            return
        }
        dismiss()
    }
}

private struct LegacyLoanDraft: Identifiable {
    let id = UUID()
    var counterparty: String
    var amountText: String
    var direction: LoanDirection = .borrowed
    var hasDueDate: Bool = false
    var dueDate: Date = .now
}

@MainActor
struct LoanEditor: View {
    @ObservedObject var store: LedgerStore
    let loan: Loan?
    let onSave: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var counterparty: String
    @State private var direction: LoanDirection
    @State private var amountText: String
    @State private var fundedAmountText: String
    @State private var loanCurrency: LedgerCurrency
    @State private var startedAt: Date
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var selectedAccountID: UUID?
    @State private var errorMessage: String?

    init(store: LedgerStore, loan: Loan? = nil, onSave: (() -> Void)? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.loan = loan
        self.onSave = onSave
        _counterparty = State(initialValue: loan?.counterparty ?? "")
        _direction = State(initialValue: loan?.direction ?? .borrowed)
        _amountText = State(initialValue: "")
        _fundedAmountText = State(initialValue: "")
        _startedAt = State(initialValue: loan?.startedAt ?? .now)
        _hasDueDate = State(initialValue: loan?.dueDate != nil)
        _dueDate = State(initialValue: loan?.dueDate ?? .now)
        let firstAccount = store.activeAccounts.first { $0.type == .cash || $0.type == .bankAccount }
        let accountID = loan?.settlementAccountID ?? firstAccount?.id
        _selectedAccountID = State(initialValue: accountID)
        _loanCurrency = State(
            initialValue: loan?.currency
                ?? store.activeAccounts.first(where: { $0.id == accountID })?.currency
                ?? .usd
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Loan") {
                    if loan == nil {
                        Picker("Direction", selection: $direction) {
                            ForEach(LoanDirection.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                    }
                    TextField(loan?.direction.counterpartyLabel ?? direction.counterpartyLabel, text: $counterparty)
                    if loan == nil {
                        CurrencyInputField("Total amount owed", text: $amountText, currency: $loanCurrency)
                        CurrencyInputField(
                            direction == .lent ? "Amount given" : "Amount received",
                            text: $fundedAmountText,
                            currency: $loanCurrency
                        )
                        Text("Leave the funded amount blank to use the total owed. The total can include manually entered interest.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        DatePicker("Started", selection: $startedAt, in: Date.distantPast...Date.now, displayedComponents: .date)
                    }
                    Toggle("Add due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    }
                }

                if loan == nil {
                    Section(direction == .lent ? "Money given from" : "Money received into") {
                        if eligibleAccounts.isEmpty {
                            Text("Add a cash or bank account before creating a loan.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Account", selection: selectedAccountBinding) {
                                ForEach(eligibleAccounts) { account in
                                    Text("\(account.name) · \(account.currency.rawValue)")
                                        .tag(Optional(account.id))
                                }
                            }
                        }
                        if let cashMovementAmount {
                            LabeledContent("Cash movement") {
                                Text(cashMovementAmount.formatted)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            if let fundingRate {
                                Text(fundingRate.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if needsFundingRate {
                            Text("Add an exchange rate in More → Exchange Rates to record the funding movement.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text("The loan uses its own currency. Funding is converted to the selected cash account with a saved exchange rate, and principal stays out of income and expense totals.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle(loan == nil ? "New loan" : "Edit loan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Loan not saved", message: $errorMessage)
        }
    }

    private var eligibleAccounts: [Account] {
        store.activeAccounts.filter { !$0.isArchived && ($0.type == .cash || $0.type == .bankAccount) }
    }

    private var selectedAccount: Account? {
        eligibleAccounts.first { $0.id == selectedAccountID }
    }

    private var fundingRate: ExchangeRate? {
        guard let selectedAccount, selectedAccount.currency != loanCurrency else { return nil }
        return store.exchangeRate(base: loanCurrency, quote: selectedAccount.currency)
    }

    private var needsFundingRate: Bool {
        selectedAccount.map { $0.currency != loanCurrency } ?? false
    }

    private var cashMovementAmount: Money? {
        guard let selectedAccount,
              let principalAmount = fundingAmount,
              let minorUnits = financeConvertedMinorUnits(
                  principalAmount,
                  to: selectedAccount.currency,
                  using: fundingRate
              ) else { return nil }
        return Money(currency: selectedAccount.currency, minorUnits: minorUnits)
    }

    private var fundingAmount: Money? {
        guard let totalOwed = Money.parse(amountText, currency: loanCurrency) else { return nil }
        let fundedValue = fundedAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        return fundedValue.isEmpty
            ? totalOwed
            : Money.parse(fundedValue, currency: loanCurrency)
    }

    private var selectedAccountBinding: Binding<UUID?> {
        Binding(get: { selectedAccountID }, set: { selectedAccountID = $0 })
    }

    private func save() {
        let party = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !party.isEmpty else {
            errorMessage = "Enter the person or organization for this loan."
            return
        }
        if var existing = loan {
            existing.counterparty = party
            existing.dueDate = hasDueDate ? dueDate : nil
            guard store.updateLoan(existing) else {
                errorMessage = store.lastActionStatus ?? "The loan could not be updated."
                return
            }
            onSave?()
            dismiss()
            return
        }

        guard let account = selectedAccount,
              let amount = Money.parse(amountText, currency: loanCurrency),
              amount.minorUnits > 0,
              let fundingAmount,
              fundingAmount.minorUnits > 0,
              let cashMovementAmount,
              cashMovementAmount.minorUnits > 0 else {
            errorMessage = needsFundingRate && fundingRate == nil
                ? "Add an exchange rate in More → Exchange Rates to fund this loan in a different currency."
                : "Enter a positive amount and choose a cash or bank account."
            return
        }
        let dueDate = hasDueDate ? self.dueDate : nil

        let loanID = UUID()
        let transactionID = UUID()
        let loan = Loan(
            id: loanID,
            counterparty: party,
            direction: direction,
            currency: amount.currency,
            startingAmount: amount,
            startedAt: startedAt,
            dueDate: dueDate,
            settlementAccountID: account.id,
            fundingTransactionID: transactionID
        )
        let movement = MoneyMovement(accountID: account.id, money: cashMovementAmount)
        let transaction = LedgerTransaction(
            id: transactionID,
            date: startedAt,
            note: direction == .lent ? "Loan to \(party)" : "Loan from \(party)",
            kind: .transfer,
            categoryID: nil,
            outflows: direction == .lent ? [movement] : [],
            inflows: direction == .borrowed ? [movement] : [],
            exchangeRate: fundingRate,
            loanID: loanID,
            loanActivity: .funding,
            loanPrincipalAmount: fundingAmount
        )
        guard store.addLoan(loan, fundingTransaction: transaction) else {
            errorMessage = store.lastActionStatus ?? "The loan could not be saved."
            return
        }
        onSave?()
        dismiss()
    }
}

@MainActor
struct LoanDetailView: View {
    @ObservedObject var store: LedgerStore
    let loanID: UUID
    let showsCloseButton: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingLoan = false
    @State private var isPresentingPayment = false
    @State private var editingPayment: LoanPayment?
    @State private var deletingPayment: LoanPayment?
    @State private var errorMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(store: LedgerStore, loanID: UUID, showsCloseButton: Bool = false) {
        _store = ObservedObject(wrappedValue: store)
        self.loanID = loanID
        self.showsCloseButton = showsCloseButton
    }

    private var loan: Loan? { store.loan(with: loanID) }

    var body: some View {
        Group {
            if let loan {
                detail(loan)
            } else {
                ContentUnavailableView("Loan unavailable", systemImage: "arrow.left.arrow.right.circle")
            }
        }
        .navigationTitle(loan?.counterparty ?? "Loan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditingLoan = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit loan")
            }
        }
        .sheet(isPresented: $isEditingLoan) {
            if let loan { LoanEditor(store: store, loan: loan) }
        }
        .sheet(isPresented: $isPresentingPayment) {
            if let loan { LoanPaymentEditor(store: store, loan: loan) }
        }
        .sheet(item: $editingPayment) { payment in
            if let loan,
               let transaction = store.data.transactions.first(where: { $0.id == payment.transactionID }) {
                LoanPaymentEditor(store: store, loan: loan, payment: payment, transaction: transaction)
            }
        }
        .errorMessageAlert(title: "Loan action failed", message: $errorMessage)
        .confirmationDialog(
            "Remove this payment?",
            isPresented: deletingPaymentPresented,
            titleVisibility: .visible
        ) {
            Button("Remove payment", role: .destructive) {
                if let deletingPayment,
                   !store.deleteLoanPayment(loanID: loanID, paymentID: deletingPayment.id) {
                    errorMessage = store.lastActionStatus ?? "The payment could not be removed."
                }
                deletingPayment = nil
            }
            Button("Cancel", role: .cancel) { deletingPayment = nil }
        }
    }

    private func detail(_ loan: Loan) -> some View {
        ScrollView(showsIndicators: false) {
            PocketGlassContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(loan.direction.displayName, systemImage: loan.direction == .lent ? "arrow.up.right" : "arrow.down.left")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                            Spacer()
                            Text(loan.currency.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PocketLedgerTheme.accent)
                        }
                        Text(loan.counterparty)
                            .font(.title3.weight(.semibold))
                        ProtectedAmountText(value: loan.outstandingAmount.formatted, isRevealed: areBalancesRevealed)
                            .font(.largeTitle.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(loan.isSettled ? "Settled" : "Outstanding")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(loan.isSettled ? PocketLedgerTheme.textSecondary : PocketLedgerTheme.income)
                        if let dueDate = loan.dueDate {
                            Label("Due \(dueDate.formatted(date: .long, time: .omitted))", systemImage: "calendar")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                        if let account = loan.settlementAccountID.flatMap({ store.account(with: $0) }) {
                            Label("Cash account: \(account.name)", systemImage: account.type.systemImage)
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }
                        if let funding = originalFunding(for: loan) {
                            LabeledContent(loan.direction == .lent ? "Amount given" : "Amount received") {
                                ProtectedAmountText(
                                    value: funding.amount.formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            Text("Through \(funding.account.name)")
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pocketGroupedSurface(cornerRadius: 20)

                    if !loan.isSettled {
                        Button {
                            isPresentingPayment = true
                        } label: {
                            Label(loan.direction == .lent ? "Record collection" : "Record repayment", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PocketLedgerTheme.accent)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Payment history")
                            .font(.headline)
                        if loan.payments.isEmpty {
                            Text("No payments recorded yet.")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(loan.payments.sorted { $0.date > $1.date }) { payment in
                                paymentRow(payment, loan: loan)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pocketGroupedSurface(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Started \(loan.startedAt.formatted(date: .abbreviated, time: .omitted))")
                        HStack(spacing: 4) {
                            Text("Original total")
                            ProtectedAmountText(
                                value: loan.startingAmount.formatted,
                                isRevealed: areBalancesRevealed
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .scrollIndicators(.hidden)
        .pocketScreen()
    }

    private func paymentRow(_ payment: LoanPayment, loan: Loan) -> some View {
        let transaction = store.data.transactions.first { $0.id == payment.transactionID }
        let movement = transaction.flatMap { ($0.outflows + $0.inflows).first }
        let account = movement.flatMap { store.account(with: $0.accountID) }
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(PocketLedgerTheme.income)
            VStack(alignment: .leading, spacing: 3) {
                Text(payment.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.medium))
                if let account {
                    Text("Via \(account.name)")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            ProtectedAmountText(value: payment.amount.formatted, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Menu {
                Button("Edit payment", systemImage: "pencil") { editingPayment = payment }
                Button("Remove payment", systemImage: "trash", role: .destructive) { deletingPayment = payment }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Payment actions")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PocketLedgerTheme.divider).frame(height: 1)
        }
    }

    private func originalFunding(for loan: Loan) -> (amount: Money, account: Account)? {
        guard let transactionID = loan.fundingTransactionID,
              let transaction = store.data.transactions.first(where: { $0.id == transactionID }),
              let movement = (transaction.outflows + transaction.inflows).first,
              let account = store.account(with: movement.accountID) else {
            return nil
        }
        return (movement.money, account)
    }

    private var deletingPaymentPresented: Binding<Bool> {
        Binding(get: { deletingPayment != nil }, set: { if !$0 { deletingPayment = nil } })
    }
}

@MainActor
private struct LoanPaymentEditor: View {
    @ObservedObject var store: LedgerStore
    let loan: Loan
    let payment: LoanPayment?
    let transaction: LedgerTransaction?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: UUID?
    @State private var amountText: String
    @State private var date: Date
    @State private var errorMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(
        store: LedgerStore,
        loan: Loan,
        payment: LoanPayment? = nil,
        transaction: LedgerTransaction? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.loan = loan
        self.payment = payment
        self.transaction = transaction
        let movement = transaction.flatMap { ($0.outflows + $0.inflows).first }
        let defaultAccount = loan.settlementAccountID
            ?? store.activeAccounts.first { $0.type == .cash || $0.type == .bankAccount }?.id
        let selectedID = movement?.accountID ?? defaultAccount
        _selectedAccountID = State(initialValue: selectedID)
        let selectedCurrency = store.activeAccounts.first { $0.id == selectedID }?.currency ?? loan.currency
        _amountText = State(initialValue: movement.map { selectedCurrency.formattedInput(minorUnits: $0.money.minorUnits) } ?? "")
        _date = State(initialValue: payment?.date ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(payment == nil ? "Payment" : "Edit payment") {
                    CurrencyInputField("Amount", text: $amountText, currency: paymentCurrency)
                    DatePicker("Date", selection: $date, in: Date.distantPast...Date.now, displayedComponents: .date)
                    Picker("Cash account", selection: selectedAccountBinding) {
                        ForEach(eligibleAccounts) { account in
                            Text("\(account.name) · \(account.currency.rawValue)").tag(Optional(account.id))
                        }
                    }
                }

                Section("Loan balance") {
                    LabeledContent("Outstanding") {
                        ProtectedAmountText(
                            value: loan.outstandingAmount.formatted,
                            isRevealed: areBalancesRevealed
                        )
                    }
                    if let principalAmount {
                        LabeledContent("Applied to loan") {
                            ProtectedAmountText(
                                value: principalAmount.formatted,
                                isRevealed: areBalancesRevealed
                            )
                        }
                    } else if needsExchangeRate {
                        Text("Add an exchange rate in More → Exchange Rates to record this payment in a different currency.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle(payment == nil ? (loan.direction == .lent ? "Record collection" : "Record repayment") : "Edit payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .errorMessageAlert(title: "Payment not saved", message: $errorMessage)
        }
    }

    private var eligibleAccounts: [Account] {
        store.activeAccounts.filter { !$0.isArchived && ($0.type == .cash || $0.type == .bankAccount) }
    }

    private var selectedAccount: Account? { eligibleAccounts.first { $0.id == selectedAccountID } }
    private var paymentCurrency: LedgerCurrency { selectedAccount?.currency ?? loan.currency }

    private var needsExchangeRate: Bool {
        selectedAccount.map { $0.currency != loan.currency } ?? false
    }

    private var selectedAccountBinding: Binding<UUID?> {
        Binding(get: { selectedAccountID }, set: { selectedAccountID = $0 })
    }

    private var rate: ExchangeRate? {
        guard paymentCurrency != loan.currency else { return nil }
        return store.exchangeRate(base: paymentCurrency, quote: loan.currency)
    }

    private var principalAmount: Money? {
        guard let cashAmount = Money.parse(amountText, currency: paymentCurrency),
              let minorUnits = financeConvertedMinorUnits(cashAmount, to: loan.currency, using: rate) else {
            return nil
        }
        return Money(currency: loan.currency, minorUnits: minorUnits)
    }

    private var canSave: Bool {
        guard let selectedAccount,
              let principalAmount,
              principalAmount.minorUnits > 0,
              date <= .now else { return false }
        let maximum = loan.outstandingAmount.minorUnits + (payment?.amount.minorUnits ?? 0)
        return principalAmount.minorUnits <= maximum
    }

    private func save() {
        guard let account = selectedAccount,
              let cashAmount = Money.parse(amountText, currency: account.currency),
              let principalAmount,
              principalAmount.minorUnits > 0,
              date <= .now else {
            errorMessage = "Enter a valid payment and choose a cash or bank account."
            return
        }
        let maximum = loan.outstandingAmount.minorUnits + (payment?.amount.minorUnits ?? 0)
        guard principalAmount.minorUnits <= maximum else {
            errorMessage = "The payment cannot exceed the remaining loan balance."
            return
        }

        let paymentID = payment?.id ?? UUID()
        let transactionID = payment?.transactionID ?? UUID()
        let newPayment = LoanPayment(
            id: paymentID,
            date: date,
            amount: principalAmount,
            transactionID: transactionID
        )
        let oldMovement = transaction.flatMap { ($0.outflows + $0.inflows).first }
        let movement = MoneyMovement(
            id: oldMovement?.id ?? UUID(),
            accountID: account.id,
            money: cashAmount
        )
        let updatedTransaction = LedgerTransaction(
            id: transactionID,
            date: date,
            note: loan.direction == .lent ? "Loan collection from \(loan.counterparty)" : "Loan repayment to \(loan.counterparty)",
            kind: .transfer,
            categoryID: nil,
            outflows: loan.direction == .borrowed ? [movement] : [],
            inflows: loan.direction == .lent ? [movement] : [],
            exchangeRate: rate,
            attachmentIDs: transaction?.attachmentIDs ?? [],
            loanID: loan.id,
            loanPaymentID: paymentID,
            loanActivity: .payment,
            loanPrincipalAmount: principalAmount
        )

        let saved = payment == nil
            ? store.recordLoanPayment(newPayment, for: loan.id, transaction: updatedTransaction)
            : store.updateLoanPayment(newPayment, for: loan.id, transaction: updatedTransaction)
        guard saved else {
            errorMessage = store.lastActionStatus ?? "The payment could not be saved."
            return
        }
        dismiss()
    }
}
