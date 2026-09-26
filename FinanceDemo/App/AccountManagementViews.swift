import Foundation
import SwiftUI

@MainActor
struct AccountsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @State private var isPresentingAccount = false
    @State private var editingAccount: Account?
    @State private var isArchivedAccountsExpanded = false
    @State private var isAccountSummaryExpanded = false
    @State private var expandedPositionCurrency: LedgerCurrency?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    var body: some View {
        List {
            DisclosureGroup(isExpanded: $isAccountSummaryExpanded) {
                VStack(spacing: 12) {
                    accountTypeTotalsSummary
                    globalPositionSummary
                }
                .padding(.top, 8)
            } label: {
                Label("Account overview", systemImage: "chart.pie")
                    .font(.headline)
                    .foregroundStyle(PocketLedgerTheme.textPrimary)
            }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(AccountType.allCases) { accountType in
                let accounts = store.activeAccounts.filter { $0.type == accountType }
                if !accounts.isEmpty {
                    accountSection(type: accountType, accounts: accounts)
                }
            }

            if !archivedAccounts.isEmpty {
                archivedAccountsSection
            }

            Text(store.storageAvailable && store.sharedStorageAvailable
                 ? "Stored locally in the shared app container."
                 : store.storageAvailable
                 ? "Stored persistently on this device; widget sharing is unavailable."
                 : "Persistent storage is unavailable; changes cannot be saved.")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 20, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .pocketScreen()
        .safeAreaInset(edge: .top, spacing: 0) {
            screenSubtitle
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(PocketLedgerTheme.background)
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentAccount(nil)
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .accessibilityLabel("Add account")
            }
        }
        .sheet(isPresented: $isPresentingAccount, onDismiss: { editingAccount = nil }) {
            AccountEditor(store: store, account: editingAccount)
        }
        .onChange(of: archivedAccounts.isEmpty) { _, isEmpty in
            if isEmpty {
                isArchivedAccountsExpanded = false
            }
        }
    }

    private var accountTypeTotalsSummary: some View {
        let activeAccounts = store.activeAccounts
        let includedAccounts = activeAccounts.filter(\.includeInTotals)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Account totals by type")
                        .font(.title3.weight(.bold))
                    Text("Included balances stay in their account currency")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer(minLength: 8)
            }

            if includedAccounts.isEmpty {
                Text(activeAccounts.isEmpty
                     ? "Add an account to see totals by type."
                     : "No accounts are currently included in totals.")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AccountType.allCases.filter { type in
                        includedAccounts.contains { $0.type == type }
                    }) { type in
                        let typeAccounts = includedAccounts.filter { $0.type == type }
                        HStack(alignment: .top, spacing: 8) {
                            Label(type.displayName, systemImage: type.systemImage)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .frame(width: 112, alignment: .leading)

                            Spacer(minLength: 4)

                            VStack(alignment: .trailing, spacing: 5) {
                                ForEach(LedgerCurrency.allCases.filter { currency in
                                    typeAccounts.contains { $0.currency == currency }
                                }) { currency in
                                    let currencyAccounts = typeAccounts.filter { $0.currency == currency }
                                    let total = currencyAccounts.reduce(Int64.zero) { total, account in
                                        total + store.balance(for: account).minorUnits
                                    }
                                    HStack(spacing: 6) {
                                        Text(currency.rawValue)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                                        ProtectedAmountText(
                                            value: Money(currency: currency, minorUnits: total).formatted,
                                            isRevealed: areBalancesRevealed
                                        )
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(PocketLedgerTheme.textPrimary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .pocketCard()
    }

    private var globalPositionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Net worth by currency")
                        .font(.title3.weight(.bold))
                    Text("Tap a currency to see assets and liabilities")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }

                Spacer()

                Image(systemName: "chart.pie.fill")
                    .foregroundStyle(PocketLedgerTheme.accent)
            }

            VStack(spacing: 0) {
                ForEach(LedgerCurrency.allCases) { currency in
                    if currency != LedgerCurrency.allCases[0] {
                        Divider().overlay(PocketLedgerTheme.divider)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedPositionCurrency == currency },
                            set: { expandedPositionCurrency = $0 ? currency : nil }
                        )) {
                            accountPositionRow(
                                title: "Assets",
                                value: store.assetBalance(for: currency),
                                tint: PocketLedgerTheme.income
                            )
                            accountPositionRow(
                                title: "Liabilities",
                                value: store.liabilityBalance(for: currency),
                                tint: PocketLedgerTheme.warning
                            )
                        } label: {
                            HStack(spacing: 10) {
                                Text(currency.rawValue)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                                Spacer(minLength: 8)

                                ProtectedAmountText(
                                    value: store.netWorth(for: currency).formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.headline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(PocketLedgerTheme.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                        }
                        .tint(PocketLedgerTheme.textSecondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .pocketCard()
    }

    private func accountPositionRow(
        title: String,
        value: Money,
        tint: Color
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Spacer()

            ProtectedAmountText(value: value.formatted, isRevealed: areBalancesRevealed)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    private var screenSubtitle: some View {
        HStack(spacing: 12) {
            Text("Tap for activity · hold for options · drag to reorder")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            BalanceVisibilityControl(security: security, isRevealed: $areBalancesRevealed)
                .accessibilityIdentifier("balance-visibility-control")
        }
    }

    private func accountSection(type: AccountType, accounts: [Account]) -> some View {
        Section {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { entry in
                let account = entry.element
                HStack(spacing: 4) {
                    NavigationLink {
                        AccountDetailView(store: store, security: security, accountID: account.id)
                    } label: {
                        AccountRow(
                            account: account,
                            balance: store.balance(for: account),
                            areBalancesRevealed: areBalancesRevealed
                        )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") {
                        presentAccount(account)
                    }
                    Button(
                        account.includeInTotals ? "Exclude from totals" : "Include in totals",
                        systemImage: account.includeInTotals ? "eye.slash" : "eye"
                    ) {
                        _ = store.setAccountIncludedInTotals(
                            accountID: account.id,
                            included: !account.includeInTotals
                        )
                    }
                    Button("Archive", systemImage: "archivebox") {
                        _ = store.setAccountArchived(accountID: account.id, isArchived: true)
                    }
                }
                .draggable(account.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let draggedID = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    return store.moveAccount(accountID: draggedID, beforeAccountID: account.id)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    PocketCircularSwipeAction(
                        title: "Edit",
                        systemImage: "pencil",
                        tint: .yellow,
                        iconColor: .black
                    ) {
                        presentAccount(account)
                    }
                    PocketCircularSwipeAction(
                        title: "Archive",
                        systemImage: "archivebox",
                        tint: PocketLedgerTheme.warning
                    ) {
                        _ = store.setAccountArchived(accountID: account.id, isArchived: true)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    PocketCircularSwipeAction(
                        title: account.includeInTotals ? "Exclude" : "Include",
                        systemImage: account.includeInTotals ? "eye.slash" : "eye",
                        tint: account.includeInTotals ? PocketLedgerTheme.textSecondary : PocketLedgerTheme.positive
                    ) {
                        _ = store.setAccountIncludedInTotals(
                            accountID: account.id,
                            included: !account.includeInTotals
                        )
                    }
                }
                .listRowInsets(
                    EdgeInsets(
                        top: 0,
                        leading: PocketLedgerTheme.screenHorizontalPadding * 2,
                        bottom: 0,
                        trailing: PocketLedgerTheme.screenHorizontalPadding * 2
                    )
                )
                .listRowBackground(
                    ledgerGroupedRowBackground(
                        isFirst: entry.offset == 0,
                        isLast: entry.offset == accounts.count - 1
                    )
                )
                .listRowSeparatorTint(PocketLedgerTheme.divider)
                .listRowSeparator(
                    entry.offset == accounts.count - 1 ? .hidden : .visible,
                    edges: .bottom
                )
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: type.systemImage)
                    .foregroundStyle(PocketLedgerTheme.accent)
                Text(type.displayName)
                    .font(.caption.weight(.bold))
                Text("\(accounts.count) \(accounts.count == 1 ? "account" : "accounts")")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }
            .textCase(nil)
        }
        .listSectionSeparator(.hidden)
    }

    private var archivedAccounts: [Account] {
        store.data.accounts.filter(\.isArchived)
    }

    private var archivedAccountsSection: some View {
        Section {
            if isArchivedAccountsExpanded {
                ForEach(Array(archivedAccounts.enumerated()), id: \.element.id) { entry in
                    let account = entry.element
                    HStack(spacing: 12) {
                        PocketIcon(
                            systemImage: account.type.systemImage,
                            tint: PocketLedgerTheme.textTertiary,
                            size: 34
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .font(.subheadline.weight(.semibold))
                            Text("\(account.type.displayName) · \(account.currency.rawValue)")
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }

                        Spacer(minLength: 8)

                        Button("Restore", systemImage: "arrow.uturn.backward") {
                            _ = store.setAccountArchived(accountID: account.id, isArchived: false)
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    .frame(minHeight: 68)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        PocketCircularSwipeAction(
                            title: "Restore",
                            systemImage: "arrow.uturn.backward",
                            tint: PocketLedgerTheme.accent
                        ) {
                            _ = store.setAccountArchived(accountID: account.id, isArchived: false)
                        }
                    }
                    .listRowInsets(
                        EdgeInsets(
                            top: 0,
                            leading: PocketLedgerTheme.screenHorizontalPadding * 2,
                            bottom: 0,
                            trailing: PocketLedgerTheme.screenHorizontalPadding * 2
                        )
                    )
                    .listRowBackground(
                        ledgerGroupedRowBackground(
                            isFirst: entry.offset == 0,
                            isLast: entry.offset == archivedAccounts.count - 1
                        )
                    )
                    .listRowSeparatorTint(PocketLedgerTheme.divider)
                    .listRowSeparator(
                        entry.offset == archivedAccounts.count - 1 ? .hidden : .visible,
                        edges: .bottom
                    )
                }
            }
        } header: {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isArchivedAccountsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Archived")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                    Text("\(archivedAccounts.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .rotationEffect(.degrees(isArchivedAccountsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived accounts")
            .accessibilityValue(isArchivedAccountsExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isArchivedAccountsExpanded ? "Hides archived accounts" : "Shows archived accounts")
            .textCase(nil)
        } footer: {
            Text("Archived accounts stay available for historical transactions but are hidden from new account selections.")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .listSectionSeparator(.hidden)
    }

    private func presentAccount(_ account: Account?) {
        editingAccount = account
        isPresentingAccount = true
    }
}

func ledgerGroupedRowBackground(isFirst: Bool, isLast: Bool) -> some View {
    UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
            topLeading: isFirst ? 18 : 0,
            bottomLeading: isLast ? 18 : 0,
            bottomTrailing: isLast ? 18 : 0,
            topTrailing: isFirst ? 18 : 0
        ),
        style: .continuous
    )
    .fill(PocketLedgerTheme.surface)
    .padding(.horizontal, 16)
}

@MainActor
private struct AccountRow: View {
    let account: Account
    let balance: Money
    let areBalancesRevealed: Bool

    var body: some View {
        HStack(spacing: 12) {
            PocketIcon(
                systemImage: account.type.systemImage,
                tint: account.type == .loan || !account.includeInTotals
                    ? PocketLedgerTheme.warning
                    : PocketLedgerTheme.income,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                Text(account.type.displayName)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                if !account.includeInTotals {
                    Text("Excluded from totals")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(PocketLedgerTheme.warning)
                }
                if account.isArchived {
                    Text("Archived")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
            }

            Spacer()

            ProtectedAmountText(value: balance.formatted, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(account.type == .loan || !account.includeInTotals
                    ? PocketLedgerTheme.warning
                    : PocketLedgerTheme.textPrimary)
        }
        .frame(minHeight: 68)
    }
}

@MainActor
struct AccountEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account?
    let initialCurrency: LedgerCurrency?
    let onSaved: (Account) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: AccountType = .cash
    @State private var currency: LedgerCurrency = .usd
    @State private var openingBalance = "0"
    @State private var includeInTotals = true
    @State private var errorMessage: String?
    @State private var pendingAccount: Account?
    @State private var isConfirmingCurrencyChange = false
    @State private var isConfirmingDiscard = false

    init(
        store: LedgerStore,
        account: Account? = nil,
        initialCurrency: LedgerCurrency? = nil,
        onSaved: @escaping (Account) -> Void = { _ in }
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account
        self.initialCurrency = initialCurrency
        self.onSaved = onSaved
        _name = State(initialValue: account?.name ?? "")
        _type = State(initialValue: account?.type ?? .cash)
        _currency = State(initialValue: account?.currency ?? initialCurrency ?? .usd)
        _openingBalance = State(
            initialValue: account.map {
                NSDecimalNumber(
                    decimal: Decimal($0.openingBalance.minorUnits) / Decimal($0.currency.minorUnitScale)
                ).stringValue
            } ?? "0"
        )
        _includeInTotals = State(initialValue: account?.includeInTotals ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases) { accountType in
                            Label(accountType.displayName, systemImage: accountType.systemImage)
                                .tag(accountType)
                        }
                    }
                    if hasCurrencyImpact {
                        Text("Changing currency updates this account's opening balance and all related transactions. Amounts keep their displayed numeric value; no exchange-rate conversion is applied.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Include in totals and metrics", isOn: $includeInTotals)
                    Text("Turn this off for assets or investments you want to track separately.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Opening balance") {
                    CurrencyInputField("Amount", text: $openingBalance, currency: $currency)
                    Text("The amount is stored in the account's own currency.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle(account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .onChange(of: currency) { oldCurrency, newCurrency in
                guard let account, oldCurrency != newCurrency,
                      let balance = Money.parse(openingBalance, currency: oldCurrency) else {
                    return
                }
                let migratedBalance = balance.recast(to: newCurrency)
                openingBalance = NSDecimalNumber(
                    decimal: Decimal(migratedBalance.minorUnits)
                        / Decimal(newCurrency.minorUnitScale)
                ).stringValue
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .alert("Account not saved", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Change account currency?", isPresented: $isConfirmingCurrencyChange, titleVisibility: .visible) {
                Button("Save currency change") { confirmCurrencyChange() }
                Button("Cancel", role: .cancel) { pendingAccount = nil }
            } message: {
                Text(currencyChangeSummary)
            }
            .confirmationDialog("Discard account changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter an account name."
            return
        }
        guard let balance = Money.parse(openingBalance, currency: currency) else {
            errorMessage = "Enter a valid opening balance."
            return
        }

        let value = Account(
            id: account?.id ?? UUID(),
            name: trimmedName,
            type: type,
            currency: currency,
            openingBalance: balance,
            includeInTotals: includeInTotals,
            isArchived: account?.isArchived ?? false
        )
        if account?.currency != nil, account?.currency != currency, hasCurrencyImpact {
            pendingAccount = value
            isConfirmingCurrencyChange = true
            return
        }
        persist(value)
    }

    private func confirmCurrencyChange() {
        guard let pendingAccount else { return }
        persist(pendingAccount)
        self.pendingAccount = nil
    }

    private func persist(_ value: Account) {
        let saved = account == nil ? store.addAccount(value) : store.updateAccount(value)
        guard saved else {
            errorMessage = store.lastActionStatus ?? "The account could not be saved."
            return
        }
        onSaved(value)
        dismiss()
    }

    private func cancel() {
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private var hasUnsavedChanges: Bool {
        let baselineCurrency = account?.currency ?? initialCurrency ?? .usd
        let baselineBalance = account?.openingBalance ?? Money(currency: baselineCurrency, minorUnits: 0)
        return name != (account?.name ?? "")
            || type != (account?.type ?? .cash)
            || currency != baselineCurrency
            || Money.parse(openingBalance, currency: currency) != baselineBalance.recast(to: currency)
            || includeInTotals != (account?.includeInTotals ?? true)
    }

    private var currencyChangeSummary: String {
        guard let account else { return "" }
        let transactionCount = store.data.transactions.filter {
            ($0.outflows + $0.inflows).contains { $0.accountID == account.id }
        }.count
        let scheduleCount = store.data.scheduledTransactions.filter {
            ($0.outflows + $0.inflows).contains { $0.accountID == account.id }
        }.count
        let transactionLabel = transactionCount == 1 ? "transaction" : "transactions"
        let scheduleLabel = scheduleCount == 1 ? "scheduled entry" : "scheduled entries"
        let transactionExample = store.data.transactions.lazy
            .flatMap { $0.outflows + $0.inflows }
            .first(where: { $0.accountID == account.id })?.money
        let scheduleExample = store.data.scheduledTransactions.lazy
            .flatMap { $0.outflows + $0.inflows }
            .first(where: { $0.accountID == account.id })?.money
        let recordExample = transactionExample ?? scheduleExample
        let recordLabel = transactionExample != nil ? "Transaction" : "Scheduled entry"
        var previews = [
            "Opening balance: \(account.openingBalance.formatted) → \(account.openingBalance.recast(to: currency).formatted)"
        ]
        if let recordExample {
            previews.append("\(recordLabel): \(recordExample.formatted) → \(recordExample.recast(to: currency).formatted)")
        }
        let preview = previews.joined(separator: " · ")
        return "Switching to \(currency.rawValue) updates the opening balance, \(transactionCount) historical \(transactionLabel), and \(scheduleCount) \(scheduleLabel). \(preview). Amounts are rounded to the new currency’s precision; no exchange-rate conversion is applied. Export a full backup from More → Import & Backup first if you may need to restore the original values."
    }

    private var hasCurrencyImpact: Bool {
        guard let account else { return false }
        return account.openingBalance.minorUnits != 0
            || store.data.transactions.contains {
                ($0.outflows + $0.inflows).contains { $0.accountID == account.id }
            }
            || store.data.scheduledTransactions.contains {
                ($0.outflows + $0.inflows).contains { $0.accountID == account.id }
            }
    }
}
