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
        var outgoing: Int64 = 0
        var incoming: Int64 = 0
        for transaction in transactions {
            outgoing += transaction.outflows
                .filter { $0.accountID == account.id }
                .compactMap {
                    financeConvertedMinorUnits(
                        $0.money,
                        to: account.currency,
                        using: transaction.exchangeRate
                    )
                }
                .reduce(Int64.zero, +)
            incoming += transaction.inflows
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
    @State private var editingTransaction: LedgerTransaction?
    @State private var transactionToTemplate: LedgerTransaction?
    @State private var deletedTransactionsForUndo: [LedgerTransaction] = []
    @State private var transactionDeletionError: String?
    @State private var transactionPage = 0
    @State private var snapshot = AccountDetailSnapshot.empty
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    private let transactionsPerPage = 25

    private var account: Account? {
        store.account(with: accountID)
    }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !deletedTransactionsForUndo.isEmpty {
                    TransactionUndoBanner(
                        transactions: deletedTransactionsForUndo,
                        onUndo: {
                            if store.restoreTransactions(deletedTransactionsForUndo) {
                                deletedTransactionsForUndo.removeAll()
                            } else {
                                transactionDeletionError = store.lastActionStatus ?? "The transaction could not be restored."
                            }
                        },
                        onDismiss: { deletedTransactionsForUndo.removeAll() }
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .transactionActionAlert(message: $transactionDeletionError)
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
        let hidesGenericActivity = account.type == .physicalAsset && account.tracking?.metalPurchases.isEmpty == false
        return List {
            Section {
                PocketGlassContainer(spacing: 14) {
                    VStack(alignment: .leading, spacing: 18) {
                        balanceCard(account)
                        totalsScopeCard(account)

                        if !hidesGenericActivity {
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
                }
                .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            AssetTrackingSection(store: store, account: account, areBalancesRevealed: areBalancesRevealed)

            if !hidesGenericActivity {
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
                                onDelete: {
                                    if store.deleteTransaction(id: transaction.id) {
                                        deletedTransactionsForUndo.append(transaction)
                                    } else {
                                        transactionDeletionError = store.lastActionStatus ?? "The transaction could not be deleted."
                                    }
                                },
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
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .listSectionSpacing(24)
        .listSectionSeparator(.hidden)
        .textCase(nil)
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
                value: store.valuation(for: account).formatted,
                isRevealed: areBalancesRevealed
            )
                .font(.largeTitle.weight(.bold).monospacedDigit())
                .monospacedDigit()
                .lineLimit(2)

            if account.type == .physicalAsset || account.type == .investment {
                HStack {
                    Text("Total gain/loss")
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                    Spacer()
                    if let gain = store.gainLoss(for: account) {
                        ProtectedAmountText(value: gain.minorUnits > 0 ? "+\(gain.formatted)" : gain.formatted, isRevealed: areBalancesRevealed)
                            .foregroundStyle(gain.minorUnits >= 0 ? PocketLedgerTheme.positive : .red)
                    } else {
                        Text("Not available")
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                if let reconciliation = store.reconciliation(for: account.id) {
                    if reconciliation.difference.minorUnits == 0 {
                        Text("Reconciled \(reconciliation.lastReconciledAt.formatted(.dateTime.month(.abbreviated).day()))")
                    } else {
                        Text("Adjusted by")
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
                Button {
                    isPresentingBalanceEditor = true
                } label: {
                    Label("Adjust current balance", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(PocketLedgerTheme.accent)
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
            .alert("Balance not saved", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
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
