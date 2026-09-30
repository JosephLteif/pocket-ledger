import Foundation
import SwiftUI

private struct AccountDetailSnapshot {
    let transactions: [LedgerTransaction]
    let pageTransactions: [LedgerTransaction]
    let pageCount: Int
    let displayedPage: Int
    let incoming: Int64
    let outgoing: Int64

    static var empty: AccountDetailSnapshot {
        AccountDetailSnapshot(
            transactions: [],
            pageTransactions: [],
            pageCount: 1,
            displayedPage: 0,
            incoming: 0,
            outgoing: 0
        )
    }

    static func make(
        index: LedgerIndex,
        account: Account,
        page: Int,
        pageSize: Int
    ) -> AccountDetailSnapshot {
        let transactions = index.sortedTransactions.filter { transaction in
            transaction.outflows.contains { $0.accountID == account.id }
                || transaction.inflows.contains { $0.accountID == account.id }
        }
        func convertedTotal(_ movements: [MoneyMovement], in transaction: LedgerTransaction) -> Int64 {
            movements
                .filter { $0.accountID == account.id }
                .compactMap {
                    financeConvertedMinorUnits(
                        $0.money,
                        to: account.currency,
                        using: transaction.exchangeRate
                    )
                }
                .reduce(Int64.zero, +)
        }

        var outgoing: Int64 = 0
        var incoming: Int64 = 0
        for transaction in transactions {
            outgoing += convertedTotal(transaction.outflows, in: transaction)
            incoming += convertedTotal(transaction.inflows, in: transaction)
        }

        return AccountDetailSnapshot(
            transactions: transactions,
            pageTransactions: [],
            pageCount: 1,
            displayedPage: 0,
            incoming: incoming,
            outgoing: outgoing
        ).showingPage(page, pageSize: pageSize)
    }

    func showingPage(_ page: Int, pageSize: Int) -> AccountDetailSnapshot {
        let pageCount = max(1, (transactions.count + pageSize - 1) / pageSize)
        let displayedPage = min(page, pageCount - 1)
        let pageStart = displayedPage * pageSize

        return AccountDetailSnapshot(
            transactions: transactions,
            pageTransactions: Array(transactions.dropFirst(pageStart).prefix(pageSize)),
            pageCount: pageCount,
            displayedPage: displayedPage,
            incoming: incoming,
            outgoing: outgoing
        )
    }
}

@MainActor
struct AccountDetailView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    let accountID: UUID

    @State private var isPresentingAccountEditor = false
    @State private var isPresentingBalanceEditor = false
    @State private var isPresentingReconciliation = false
    @State private var editingTransaction: LedgerTransaction?
    @State private var transactionToTemplate: LedgerTransaction?
    @State private var transactionDeletion = TransactionDeletionState()
    @State private var transactionPage = 0
    @State private var snapshot = AccountDetailSnapshot.empty
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    private let transactionsPerPage = 25

    private var account: Account? {
        store.account(with: accountID)
    }

    var body: some View {
        content
            .transactionUndoSupport(state: $transactionDeletion, store: store)
            .navigationTitle(account?.name ?? "Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PocketLedgerToolbar(security: security) {
                    if account != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                isPresentingAccountEditor = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("Edit account")
                        }
                    }
                }
            }
            .sheet(isPresented: $isPresentingAccountEditor) {
                if let account {
                    AccountEditor(store: store, account: account)
                }
            }
            .sheet(isPresented: $isPresentingBalanceEditor) {
                if let account {
                    AccountBalanceEditor(store: store, account: account)
                }
            }
            .sheet(isPresented: $isPresentingReconciliation) {
                if let account {
                    AccountReconciliationEditor(store: store, account: account)
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                TransactionEditor(store: store, transaction: transaction)
            }
            .sheet(item: $transactionToTemplate) { transaction in
                TemplateNameEditor(store: store, transaction: transaction)
            }
            .pocketScreen()
            .onAppear(perform: refreshSnapshot)
            .onChange(of: accountID) { _, _ in
                transactionPage = 0
                refreshSnapshot()
            }
            .onChange(of: store.ledgerRevision) { _, _ in refreshSnapshot() }
    }

    @ViewBuilder
    private var content: some View {
        if let account {
            accountContent(account, snapshot: snapshot)
        } else {
            ContentUnavailableView("Account unavailable", systemImage: "wallet.pass")
        }
    }

    private func accountContent(_ account: Account, snapshot: AccountDetailSnapshot) -> some View {
        List {
            Section {
                PocketGlassContainer(spacing: 14) {
                    VStack(alignment: .leading, spacing: 18) {
                        balanceCard(account)
                        totalsScopeCard(account)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                accountActivityMetrics(account: account, snapshot: snapshot)
                            }
                            VStack(spacing: 10) {
                                accountActivityMetrics(account: account, snapshot: snapshot)
                            }
                        }
                    }
                }
                .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section {
                if snapshot.transactions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                        Text("No transactions for this account")
                            .font(.headline)
                        Text("Transactions that use this account will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowInsets(
                        EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(snapshot.pageTransactions.enumerated()), id: \.element.id) { entry in
                        let transaction = entry.element
                        TransactionRow(
                            transaction: transaction,
                            store: store,
                            onEdit: { editingTransaction = transaction },
                            onDuplicate: { _ = store.duplicateTransaction(id: transaction.id) },
                            onDelete: { transactionDeletion.delete(transaction, in: store) },
                            onSaveTemplate: { transactionToTemplate = transaction },
                            allowsActions: true,
                            accountContext: account
                        )
                        .pocketGroupedListRow(
                            index: entry.offset,
                            count: snapshot.pageTransactions.count
                        )
                    }

                    if snapshot.pageCount > 1 {
                        HStack(spacing: 16) {
                            Button {
                                transactionPage = max(0, snapshot.displayedPage - 1)
                            } label: {
                                Label("Previous", systemImage: "chevron.left")
                            }
                            .disabled(snapshot.displayedPage == 0)

                            Text("Page \(snapshot.displayedPage + 1) of \(snapshot.pageCount)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(PocketLedgerTheme.textSecondary)

                            Button {
                                transactionPage = min(snapshot.pageCount - 1, snapshot.displayedPage + 1)
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(snapshot.displayedPage == snapshot.pageCount - 1)
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .listRowInsets(
                            EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                HStack {
                    Text("Account activity")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Text("All time")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                .textCase(nil)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .pocketScreen()
        .onChange(of: transactionPage) { _, _ in refreshSnapshotPage() }
    }

    private func refreshSnapshot() {
        guard let account else {
            snapshot = .empty
            return
        }
        snapshot = AccountDetailSnapshot.make(
            index: store.ledgerIndex,
            account: account,
            page: transactionPage,
            pageSize: transactionsPerPage
        )
    }

    private func refreshSnapshotPage() {
        snapshot = snapshot.showingPage(
            transactionPage,
            pageSize: transactionsPerPage
        )
    }

    private func totalsScopeCard(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isManagedLegacyLoanAccount(account.id) {
                Label("Managed in Loans", systemImage: "arrow.left.arrow.right.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
                Text("This account remains as the history for the converted loan balances.")
                    .font(.footnote)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            } else {
                Toggle("Include in totals and metrics", isOn: Binding(
                    get: { account.includeInTotals },
                    set: { store.setAccountIncludedInTotals(accountID: account.id, included: $0) }
                ))
                Text(account.includeInTotals
                     ? "This account contributes to balances and spending metrics."
                     : "This account stays visible here but is excluded from balances and spending metrics.")
                    .font(.footnote)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
        }
        .tint(PocketLedgerTheme.accent)
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func accountActivityMetrics(account: Account, snapshot: AccountDetailSnapshot) -> some View {
        accountMetric(
            title: "Transactions",
            value: "\(snapshot.transactions.count)",
            systemImage: "arrow.left.arrow.right",
            tint: PocketLedgerTheme.accent
        )
        accountMetric(
            title: "Money in",
            value: Money(currency: account.currency, minorUnits: snapshot.incoming).formatted,
            systemImage: "arrow.down.left",
            tint: PocketLedgerTheme.income,
            protectsValue: true
        )
        accountMetric(
            title: "Money out",
            value: Money(currency: account.currency, minorUnits: snapshot.outgoing).formatted,
            systemImage: "arrow.up.right",
            tint: PocketLedgerTheme.warning,
            protectsValue: true
        )
    }

    private func balanceCard(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(account.type.displayName, systemImage: account.type.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Spacer()
                Text(account.currency.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PocketLedgerTheme.accent)
            }

            ProtectedAmountText(
                value: store.balance(for: account).formatted,
                isRevealed: areBalancesRevealed
            )
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .monospacedDigit()
                .lineLimit(2)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                if let reconciliation = store.reconciliation(for: account.id) {
                    if reconciliation.difference.minorUnits == 0 {
                        Text("Reconciled \(reconciliation.lastReconciledAt.formatted(.dateTime.month(.abbreviated).day()))")
                    } else {
                        Text(reconciliation.statementDate != nil && !reconciliation.didRecordAdjustment
                            ? "Statement difference"
                            : "Adjusted by")
                        ProtectedAmountText(
                            value: Money(
                                currency: account.currency,
                                minorUnits: Swift.abs(reconciliation.difference.minorUnits)
                            ).formatted,
                            isRevealed: areBalancesRevealed
                        )
                    }
                } else {
                    Text("Not reconciled yet")
                }
            }
            .font(.caption)
            .foregroundStyle(PocketLedgerTheme.textTertiary)

            if store.isManagedLegacyLoanAccount(account.id) {
                Text("This account’s balance is represented by the managed loans.")
                    .font(.footnote)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    Button {
                        isPresentingReconciliation = true
                    } label: {
                        Label("Reconcile statement", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(PocketLedgerTheme.accent)

                    Button {
                        isPresentingBalanceEditor = true
                    } label: {
                        Label("Adjust current balance", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(PocketLedgerTheme.accent)
                }
            }
        }
        .padding(20)
        .pocketGroupedSurface(cornerRadius: 22)
    }

    private func accountMetric(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        protectsValue: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Group {
                if protectsValue {
                    ProtectedAmountText(value: value, isRevealed: areBalancesRevealed)
                } else {
                    Text(value)
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .lineLimit(2)
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.4)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(11)
        .pocketGroupedSurface(cornerRadius: 16)
    }
}

@MainActor
private struct AccountBalanceEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @State private var balanceText: String
    @State private var recordAsTransaction = true
    @State private var note = ""
    @State private var errorMessage: String?

    init(store: LedgerStore, account: Account) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account

        let currentBalance = store.balance(for: account)
        let amount = Decimal(currentBalance.minorUnits) / Decimal(account.currency.minorUnitScale)
        _balanceText = State(initialValue: NSDecimalNumber(decimal: amount).stringValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current balance") {
                    CurrencyInputField("Current balance", text: $balanceText, currency: account.currency)
                        .font(.title2.weight(.semibold).monospacedDigit())

                    Toggle("Count as transaction", isOn: $recordAsTransaction)

                    Text(recordAsTransaction
                         ? "Creates an income or expense adjustment in the transaction list."
                         : "Updates the opening balance without adding a transaction.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if recordAsTransaction {
                    Section("Transaction details") {
                        TextField("Note (optional)", text: $note)
                        Text("The adjustment uses the account's own currency and is marked Uncategorized.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("Edit balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .errorMessageAlert(title: "Balance not saved", message: $errorMessage)
        }
    }

    private func save() {
        guard let targetBalance = Money.parse(balanceText, currency: account.currency) else {
            errorMessage = "Enter a valid balance in \(account.currency.rawValue)."
            return
        }

        let saved = store.updateAccountBalance(
            accountID: account.id,
            targetBalance: targetBalance,
            recordAsTransaction: recordAsTransaction,
            note: note
        )
        guard saved else {
            errorMessage = "The persistent database is unavailable, so this balance was not changed."
            return
        }

        dismiss()
    }
}

@MainActor
private struct AccountReconciliationEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @State private var statementDate = Calendar.current.startOfDay(for: .now)
    @State private var statementBalanceText: String
    @State private var selectedTransactionIDs: Set<UUID>
    @State private var isConfirmingDifference = false
    @State private var errorMessage: String?

    init(store: LedgerStore, account: Account) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account
        let alreadyCleared = store.reconciliation(for: account.id)?.clearedTransactionIDs ?? []
        let dateEnd = Calendar.current.dateInterval(of: .day, for: .now)?.end ?? .distantFuture
        let selectedIDs = Set(store.data.transactions.compactMap { transaction -> UUID? in
            guard transaction.date < dateEnd,
                  !alreadyCleared.contains(transaction.id),
                  (transaction.outflows + transaction.inflows).contains(where: { $0.accountID == account.id }) else { return nil }
            return transaction.id
        })
        _selectedTransactionIDs = State(initialValue: selectedIDs)
        let includedIDs = alreadyCleared.union(selectedIDs)
        let currentStatementBalance = store.data.transactions
            .filter { $0.date < dateEnd && includedIDs.contains($0.id) }
            .reduce(account.openingBalance.minorUnits) { total, transaction in
                let inflows = transaction.inflows.filter { $0.accountID == account.id }
                    .reduce(Int64.zero) { $0 + $1.money.minorUnits }
                let outflows = transaction.outflows.filter { $0.accountID == account.id }
                    .reduce(Int64.zero) { $0 + $1.money.minorUnits }
                return total + inflows - outflows
            }
        let amount = Decimal(currentStatementBalance) / Decimal(account.currency.minorUnitScale)
        _statementBalanceText = State(initialValue: NSDecimalNumber(decimal: amount).stringValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Statement") {
                    DatePicker("Statement date", selection: $statementDate, in: minimumDate ... .now, displayedComponents: .date)
                    CurrencyInputField("Closing balance", text: $statementBalanceText, currency: account.currency)
                    Text("Select the transactions that appear on this statement. Pocket Ledger keeps this record on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Matched balance") {
                        ProtectedAmountText(value: calculatedBalance.formatted, isRevealed: areBalancesRevealed)
                    }
                    LabeledContent("Difference") {
                        ProtectedAmountText(value: difference.formatted, isRevealed: areBalancesRevealed)
                    }
                } header: {
                    Text("Reconciliation")
                } footer: {
                    Text("A positive difference means the statement is higher than the selected ledger transactions.")
                }

                Section("Transactions") {
                    if eligibleTransactions.isEmpty {
                        Text("No unmatched transactions for this date.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(eligibleTransactions) { transaction in
                            Toggle(isOn: selectionBinding(for: transaction.id)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(transaction.note.isEmpty
                                        ? store.ledgerIndex.categorySummary(for: transaction)
                                        : transaction.note)
                                        .lineLimit(1)
                                    HStack {
                                        Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                        Spacer()
                                        ProtectedAmountText(
                                            value: movementAmount(for: transaction).formatted,
                                            isRevealed: areBalancesRevealed
                                        )
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("Reconcile statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(Money.parse(statementBalanceText, currency: account.currency) == nil)
                }
            }
            .confirmationDialog("Statement and selected transactions differ", isPresented: $isConfirmingDifference, titleVisibility: .visible) {
                Button("Record adjustment") { complete(recordAdjustment: true) }
                Button("Save without adjustment") { complete(recordAdjustment: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can record the difference as a dated balance-adjustment transaction or keep it for review.")
            }
            .errorMessageAlert(title: "Reconciliation not saved", message: $errorMessage)
            .onChange(of: statementDate) { _, _ in
                selectedTransactionIDs = Set(eligibleTransactions.map(\.id))
            }
        }
    }

    private var minimumDate: Date {
        store.reconciliation(for: account.id)?.statementDate ?? .distantPast
    }

    private var eligibleTransactions: [LedgerTransaction] {
        let alreadyCleared = store.reconciliation(for: account.id)?.clearedTransactionIDs ?? []
        let dateEnd = Calendar.current.dateInterval(of: .day, for: statementDate)?.end ?? .distantFuture
        return store.data.transactions
            .filter { transaction in
                transaction.date < dateEnd
                    && !alreadyCleared.contains(transaction.id)
                    && (transaction.outflows + transaction.inflows).contains(where: { $0.accountID == account.id })
            }
            .sorted { $0.date > $1.date }
    }

    private var calculatedBalance: Money {
        let priorIDs = store.reconciliation(for: account.id)?.clearedTransactionIDs ?? []
        let includedIDs = priorIDs.union(selectedTransactionIDs)
        let total = store.data.transactions
            .filter { includedIDs.contains($0.id) }
            .reduce(account.openingBalance.minorUnits) { total, transaction in
                let inflows = transaction.inflows.filter { $0.accountID == account.id }
                    .reduce(Int64.zero) { $0 + $1.money.minorUnits }
                let outflows = transaction.outflows.filter { $0.accountID == account.id }
                    .reduce(Int64.zero) { $0 + $1.money.minorUnits }
                return total + inflows - outflows
            }
        return Money(currency: account.currency, minorUnits: total)
    }

    private var difference: Money {
        guard let statementBalance = Money.parse(statementBalanceText, currency: account.currency) else {
            return Money(currency: account.currency, minorUnits: 0)
        }
        return Money(currency: account.currency, minorUnits: statementBalance.minorUnits - calculatedBalance.minorUnits)
    }

    private func movementAmount(for transaction: LedgerTransaction) -> Money {
        let inflows = transaction.inflows.filter { $0.accountID == account.id }
            .reduce(Int64.zero) { $0 + $1.money.minorUnits }
        let outflows = transaction.outflows.filter { $0.accountID == account.id }
            .reduce(Int64.zero) { $0 + $1.money.minorUnits }
        return Money(currency: account.currency, minorUnits: inflows - outflows)
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedTransactionIDs.contains(id) },
            set: { isSelected in
                if isSelected { selectedTransactionIDs.insert(id) }
                else { selectedTransactionIDs.remove(id) }
            }
        )
    }

    private func save() {
        guard Money.parse(statementBalanceText, currency: account.currency) != nil else {
            errorMessage = "Enter a valid balance in \(account.currency.rawValue)."
            return
        }
        if difference.minorUnits != 0 {
            isConfirmingDifference = true
        } else {
            complete(recordAdjustment: false)
        }
    }

    private func complete(recordAdjustment: Bool) {
        guard let statementBalance = Money.parse(statementBalanceText, currency: account.currency) else { return }
        guard store.reconcileAccountStatement(
            accountID: account.id,
            statementDate: statementDate,
            statementBalance: statementBalance,
            selectedTransactionIDs: selectedTransactionIDs,
            recordAdjustment: recordAdjustment
        ) else {
            errorMessage = store.lastActionStatus ?? "The statement could not be saved."
            return
        }
        dismiss()
    }
}
