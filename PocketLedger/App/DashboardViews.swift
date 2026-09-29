import Foundation
import SwiftUI

@MainActor
struct MoreView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    let onAddExpense: () -> Void
    let onAddAction: (AddAction) -> Void
    @State private var isShowingSetup = false
    @AppStorage(PocketLedgerTheme.appearanceModeKey) private var selectedAppearanceMode = PocketLedgerAppearanceMode.system.rawValue

    var body: some View {
        let attentionItems = store.attentionItems

        NavigationStack {
            List {
                if !attentionItems.isEmpty || !store.data.attentionState.dismissedIDs.isEmpty {
                    Section("Review") {
                        NavigationLink {
                            AttentionInboxView(store: store, security: security, onAddExpense: onAddExpense)
                        } label: {
                            Label {
                                HStack {
                                    Text("Needs attention")
                                    Spacer()
                                    Text("\(attentionItems.count)")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(PocketLedgerTheme.warning)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(PocketLedgerTheme.warning)
                            }
                        }
                        .accessibilityHint("Review unresolved ledger items")
                        .listRowBackground(PocketLedgerTheme.surface)
                    }
                }

                Section("Insights") {
                    NavigationLink {
                        MetricsView(store: store, security: security)
                    } label: {
                        Label("Metrics", systemImage: "chart.xyaxis.line")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)
                }

                Section("Planning") {
                    NavigationLink {
                        LoansView(store: store, security: security)
                    } label: {
                        Label("Loans", systemImage: "arrow.left.arrow.right.circle.fill")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

                    NavigationLink {
                        BudgetsView(store: store, security: security)
                    } label: {
                        Label("Budgets", systemImage: "chart.bar.doc.horizontal")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

                    NavigationLink {
                        ScheduledTransactionsView(store: store)
                    } label: {
                        Label("Scheduled", systemImage: "calendar.badge.clock")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

                    NavigationLink {
                        TemplatesView(store: store)
                    } label: {
                        Label("Templates", systemImage: "rectangle.stack")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)
                }

                Section("Organization") {
                    NavigationLink {
                        CategoriesView(store: store)
                    } label: {
                        Label("Categories", systemImage: "square.grid.2x2")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

                    NavigationLink {
                        ExchangeRatesView(store: store)
                    } label: {
                        Label("Exchange rates", systemImage: "arrow.left.arrow.right")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)
                }

                Section {
                    NavigationLink {
                        DataTransferView(store: store)
                    } label: {
                        Label("Import & Backup", systemImage: "externaldrive.badge.icloud")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

                    NavigationLink {
                        SecuritySettingsView(store: store, security: security)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

                    Button {
                        isShowingSetup = true
                    } label: {
                        Label("Setup guide", systemImage: "wand.and.stars")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)
                } header: {
                    Text("Data & security")
                } footer: {
                    Text("Keep advanced tools close without crowding the daily flow")
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                PocketLedgerToolbar(security: security) {
                    AddTransactionToolbar(store: store, onAction: onAddAction)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .foregroundStyle(PocketLedgerTheme.textPrimary)
            .tint(PocketLedgerTheme.accent)
            .pocketScreen()
            .preferredColorScheme(
                PocketLedgerAppearanceMode(rawValue: selectedAppearanceMode)?.preferredColorScheme
            )
            .accessibilityIdentifier("more-screen-\(PocketLedgerTheme.colorTheme.rawValue)")
            .sheet(isPresented: $isShowingSetup) {
                SetupWizardView(store: store)
            }
        }
    }
}

private enum DashboardSheet: Identifiable {
    case customization
    case transaction(LedgerTransaction)

    var id: String {
        switch self {
        case .customization:
            return "customization"
        case .transaction(let transaction):
            return "transaction-\(transaction.id.uuidString)"
        }
    }
}

@MainActor
struct DashboardView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    let onAddExpense: () -> Void
    let onShowTransactions: () -> Void
    let onAddAction: (AddAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSheet: DashboardSheet?
    @State private var transactionToTemplate: LedgerTransaction?
    @State private var transactionDeletion = TransactionDeletionState()
    @State private var snapshot = DashboardSnapshot.empty
    @State private var dashboardPreferences = DashboardPreferences.load()
    @State private var isBalanceScopeExpanded = false
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @AppStorage("pocketLedger.showAllBalanceCurrencies") private var showsAllBalanceCurrencies = false
    @AppStorage(PocketLedgerTheme.appearanceModeKey) private var selectedAppearanceMode = PocketLedgerAppearanceMode.system.rawValue

    var body: some View {
        NavigationStack {
            PocketGlassContainer(spacing: 14) {
                List {
                    dashboardListRow(dashboardDateHeader, top: 12, bottom: 0)
                    if !store.storageAvailable || !store.sharedStorageAvailable {
                        dashboardListRow(storageNotice)
                    }
                    dashboardWidgets

                    if let status = store.lastActionStatus {
                        dashboardListRow(
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                                .padding(.horizontal, 4),
                            bottom: 24
                        )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .pocketScreen()
            .transactionUndoSupport(state: $transactionDeletion, store: store)
            .accessibilityIdentifier("dashboard-\(PocketLedgerTheme.colorTheme.rawValue)")
            .preferredColorScheme(
                PocketLedgerAppearanceMode(rawValue: selectedAppearanceMode)?.preferredColorScheme
            )
            .navigationTitle("Pocket Ledger")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                PocketLedgerToolbar(security: security) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            presentedSheet = .customization
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Customize dashboard")
                        .accessibilityHint("Choose which widgets appear and reorder them")
                        .accessibilityIdentifier("dashboard-customize")
                    }
                    AddTransactionToolbar(store: store, onAction: onAddAction)
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .customization:
                    DashboardCustomizationView(preferences: $dashboardPreferences)
                case .transaction(let transaction):
                    TransactionEditor(store: store, transaction: transaction)
                }
            }
            .sheet(item: $transactionToTemplate) { transaction in
                TemplateNameEditor(store: store, transaction: transaction)
            }
            .onAppear(perform: refreshSnapshot)
            .onChange(of: store.ledgerRevision) { _, _ in
                withAnimation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion)) {
                    refreshSnapshot()
                }
            }
            .onChange(of: dashboardPreferences) { _, preferences in preferences.save() }
        }
    }

    private var dashboardDateHeader: some View {
        Text(Date.now, style: .date)
            .font(.subheadline)
            .foregroundStyle(PocketLedgerTheme.textSecondary)
    }

    @ViewBuilder
    private var dashboardWidgets: some View {
        if dashboardPreferences.enabledWidgets.isEmpty {
            dashboardListRow(dashboardEmptyState)
        } else {
            ForEach(dashboardPreferences.enabledWidgets) { widget in
                dashboardWidget(widget)
            }
        }
    }

    @ViewBuilder
    private func dashboardWidget(_ widget: DashboardWidget) -> some View {
        switch widget {
        case .balance:
            dashboardListRow(balanceHero)
        case .attention:
            dashboardListRow(attentionSnapshot)
        case .accounts:
            dashboardListRow(accountBreakdown)
        case .loans:
            dashboardListRow(loanSnapshot)
        case .monthSummary:
            dashboardListRow(monthSnapshot)
        case .recentActivity:
            recentActivity
        case .upcoming:
            dashboardListRow(upcomingSchedules)
        case .cashFlow:
            dashboardListRow(cashFlowSnapshot)
        case .budgetPulse:
            dashboardListRow(budgetSnapshot)
        case .storageStatus:
            if store.storageAvailable && store.sharedStorageAvailable {
                dashboardListRow(storageNotice)
            }
        }
    }

    private func dashboardListRow<Content: View>(
        _ content: Content,
        top: CGFloat = 8,
        bottom: CGFloat = 8
    ) -> some View {
        content
            .listRowInsets(
                EdgeInsets(
                    top: top,
                    leading: PocketLedgerTheme.screenHorizontalPadding,
                    bottom: bottom,
                    trailing: PocketLedgerTheme.screenHorizontalPadding
                )
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var dashboardEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your dashboard is empty", systemImage: "rectangle.stack.badge.plus")
                .font(.headline)
            Text("Choose the widgets you want to see here, then drag them into your preferred order.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
            Button("Choose widgets", systemImage: "slider.horizontal.3") {
                presentedSheet = .customization
            }
            .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .pocketGroupedSurface(cornerRadius: 20)
    }

    private var balanceHero: some View {
        let usedCurrencies = Set(snapshot.activeAccounts.filter(\.includeInTotals).map(\.currency))
        let currencies = showsAllBalanceCurrencies || usedCurrencies.isEmpty
            ? LedgerCurrency.allCases
            : LedgerCurrency.allCases.filter { usedCurrencies.contains($0) }

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Included balances", systemImage: "wallet.pass.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                Spacer()
                if !usedCurrencies.isEmpty, usedCurrencies.count < LedgerCurrency.allCases.count {
                    Button(showsAllBalanceCurrencies ? "Show used" : "Show all") {
                        showsAllBalanceCurrencies.toggle()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }

            VStack(spacing: 0) {
                ForEach(currencies) { currency in
                    if currency != currencies.first {
                        Divider()
                            .overlay(PocketLedgerTheme.divider)
                    }
                    balanceRow(for: currency)
                }
            }

            Text("Includes accounts marked for totals, including investments and physical assets. Loans are tracked separately in Accounts.")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .padding(20)
        .pocketGroupedSurface(cornerRadius: 22)
    }

    private func balanceRow(for currency: LedgerCurrency) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(currency.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(currency == .usd ? PocketLedgerTheme.income : PocketLedgerTheme.textSecondary)
                Text(currency.displayName)
                    .font(.caption2)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }

            Spacer(minLength: 12)

            let balance = snapshot.availableBalances[currency] ?? Money(currency: currency, minorUnits: 0)
            protectedBalanceText(balance.formatted)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.trailing)
                .contentTransition(.numericText(value: Double(balance.minorUnits)))
                .animation(
                    PocketLedgerMotion.expressive(reduceMotion: reduceMotion),
                    value: balance.minorUnits
                )
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var attentionSnapshot: some View {
        if !snapshot.attentionItems.isEmpty {
            NavigationLink {
                AttentionInboxView(store: store, security: security, onAddExpense: onAddExpense)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.warning)
                        .frame(width: 38, height: 38)
                        .pocketGlassSurface(cornerRadius: 19, tint: PocketLedgerTheme.warning.opacity(0.14))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Needs attention")
                            .font(.headline)
                            .foregroundStyle(PocketLedgerTheme.textPrimary)
                        Text("\(snapshot.attentionItems.count) area\(snapshot.attentionItems.count == 1 ? "" : "s") to review")
                            .font(.subheadline)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                .padding(16)
                .pocketGroupedSurface(cornerRadius: 20)
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(PocketLedgerTheme.warning.opacity(0.28), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Needs attention, \(snapshot.attentionItems.count) areas to review")
            .accessibilityIdentifier("dashboard-needs-attention")
        }
    }

    private var accountBreakdown: some View {
        let activeAccounts = snapshot.activeAccounts
        let includedCount = snapshot.includedAccountCount
        let excludedCount = snapshot.excludedAccountCount
        let hiddenAccountCount = AccountType.allCases.reduce(0) { total, type in
            total + max(0, activeAccounts.filter { $0.type == type }.count - 3)
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Balance scope")
                        .font(.title3.weight(.bold))
                    Text("Account balances by type")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer()
                NavigationLink {
                    AccountsView(store: store, security: security, onAddAction: onAddAction)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                .accessibilityLabel("Open accounts")
            }

            HStack(spacing: 10) {
                scopeMetric(title: "Included", value: "\(includedCount)", tint: PocketLedgerTheme.positive)
                scopeMetric(title: "Excluded", value: "\(excludedCount)", tint: PocketLedgerTheme.textTertiary)
            }

            Text(excludedCount == 0
                 ? "Included accounts feed totals; loans remain separate from included balances."
                 : "Excluded accounts remain visible in Accounts but do not affect balances or metrics. Loans remain separate from included balances.")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            if activeAccounts.isEmpty {
                Text("Add an account to start tracking a balance.")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            } else {
                ForEach(AccountType.allCases) { type in
                    let accounts = activeAccounts.filter { $0.type == type }
                    if !accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Label(type.displayName, systemImage: type.systemImage)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PocketLedgerTheme.textSecondary)

                            ForEach(isBalanceScopeExpanded ? accounts : Array(accounts.prefix(3))) { account in
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(account.includeInTotals ? PocketLedgerTheme.accent : PocketLedgerTheme.textTertiary)
                                        .frame(width: 7, height: 7)
                                    Text(account.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    protectedBalanceText(store.ledgerIndex.balance(for: account).formatted)
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(account.includeInTotals ? PocketLedgerTheme.textPrimary : PocketLedgerTheme.textTertiary)
                                }
                            }
                        }
                    }
                }

                if hiddenAccountCount > 0 {
                    Button(isBalanceScopeExpanded ? "Show fewer accounts" : "+\(hiddenAccountCount) more") {
                        withAnimation(.snappy(duration: 0.2)) {
                            isBalanceScopeExpanded.toggle()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
                    .buttonStyle(.plain)
                    .accessibilityHint(isBalanceScopeExpanded ? "Collapses the account list" : "Shows every account")
                }
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    private var loanSnapshot: some View {
        let activeLoans = store.data.loans.filter { !$0.isSettled }
        let currencies = LedgerCurrency.allCases.filter { currency in
            activeLoans.contains { $0.currency == currency }
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let dueSoonLimit = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let overdueCount = activeLoans.filter { loan in
            loan.dueDate.map { calendar.startOfDay(for: $0) < today } == true
        }.count
        let dueSoonCount = activeLoans.filter { loan in
            guard let dueDate = loan.dueDate else { return false }
            let day = calendar.startOfDay(for: dueDate)
            return day >= today && day < dueSoonLimit
        }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Loans")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                    Text(activeLoans.isEmpty ? "No active loans" : "\(activeLoans.count) active")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer()
                NavigationLink {
                    LoansView(store: store, security: security)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                .accessibilityLabel("Open loans")
            }

            if activeLoans.isEmpty {
                Button {
                    onAddAction(.loan)
                } label: {
                    Label("Add a loan", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketLedgerTheme.accent)
            } else {
                ForEach(currencies) { currency in
                    HStack(spacing: 12) {
                        Text(currency.rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Lent")
                                .font(.caption2)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                            ProtectedAmountText(
                                value: store.ledgerIndex.lentLoanBalance(for: currency).formatted,
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
                                value: store.ledgerIndex.borrowedLoanBalance(for: currency).formatted,
                                isRevealed: areBalancesRevealed
                            )
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(PocketLedgerTheme.warning)
                        }
                    }
                }

                HStack(spacing: 8) {
                    loanStatusCount(title: "Due soon", count: dueSoonCount, tint: PocketLedgerTheme.accent)
                    loanStatusCount(title: "Overdue", count: overdueCount, tint: PocketLedgerTheme.warning)
                }
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
        .accessibilityIdentifier("dashboard-loans")
    }

    private func loanStatusCount(title: String, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)")
                .font(.headline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func protectedBalanceText(_ value: String) -> some View {
        ProtectedAmountText(value: value, isRevealed: areBalancesRevealed)
    }

    private func scopeMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .pocketGroupedSurface(cornerRadius: 15)
    }

    private var monthSnapshot: some View {
        let expenses = snapshot.monthExpenses

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "This month", detail: Date.now.formatted(.dateTime.month(.wide).year()))

            HStack(spacing: 10) {
                NavigationLink {
                    TransactionsView(
                        store: store,
                        onAddExpense: onAddExpense,
                        security: security,
                        initialFilter: .all,
                        initialPeriod: .thisMonth
                    )
                } label: {
                    snapshotMetric(
                        title: "Transactions",
                        value: "\(snapshot.monthTransactionCount)",
                        systemImage: "arrow.left.arrow.right",
                        tint: PocketLedgerTheme.income
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    TransactionsView(
                        store: store,
                        onAddExpense: onAddExpense,
                        security: security,
                        initialFilter: .expense,
                        initialPeriod: .thisMonth,
                        initialSearch: snapshot.topCategory ?? ""
                    )
                } label: {
                    snapshotMetric(
                        title: "Top category",
                        value: snapshot.topCategory ?? "No activity",
                        systemImage: "tag.fill",
                        tint: PocketLedgerTheme.accent
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                ForEach(LedgerCurrency.allCases.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().overlay(PocketLedgerTheme.divider)
                    }
                    let currency = LedgerCurrency.allCases[index]
                    monthExpenseRow(currency: currency, total: expenses[currency] ?? 0)
                }
            }
            .padding(14)
            .pocketGroupedSurface(cornerRadius: 17)
        }
    }

    @ViewBuilder
    private var upcomingSchedules: some View {
        let schedules = snapshot.upcomingSchedules

        if !schedules.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeader(title: "Upcoming", detail: "Bills & recurring entries")
                    NavigationLink {
                        ScheduledTransactionsView(store: store)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                    }
                    .accessibilityLabel("Open scheduled transactions")
                }

                VStack(spacing: 0) {
                    ForEach(Array(schedules.prefix(3))) { schedule in
                        upcomingScheduleRow(schedule)
                        if schedule.id != schedules.prefix(3).last?.id {
                            Divider().overlay(PocketLedgerTheme.divider)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .pocketGroupedSurface(cornerRadius: 17)

                if schedules.count > 3 {
                    Text("+\(schedules.count - 3) more scheduled \(schedules.count - 3 == 1 ? "entry" : "entries")")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func upcomingScheduleRow(_ schedule: ScheduledTransaction) -> some View {
        let amountSummary = store.transactionSummary(schedule.transactionTemplate)
        let accessibleAmountSummary = areBalancesRevealed ? amountSummary : "Hidden amount"

        return HStack(spacing: 12) {
            Image(systemName: schedule.kind == .income ? "arrow.down.left" : "calendar.badge.clock")
                .font(.body.weight(.semibold))
                .foregroundStyle(schedule.kind == .income ? PocketLedgerTheme.income : PocketLedgerTheme.accent)
                .frame(width: 28, height: 28)
                .pocketGlassSurface(cornerRadius: 14, tint: PocketLedgerTheme.accent.opacity(0.14))

            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.note.isEmpty ? schedule.kind.displayName : schedule.note)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                ProtectedAmountText(value: amountSummary, isRevealed: areBalancesRevealed)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(upcomingDateLabel(schedule.nextRunDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
                Text(schedule.nextRunDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(schedule.note.isEmpty ? schedule.kind.displayName : schedule.note), \(accessibleAmountSummary), \(schedule.nextRunDate.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    private func upcomingDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0

        switch days {
        case ..<0:
            return "Due"
        case 0:
            return "Today"
        case 1:
            return "Tomorrow"
        case 2...6:
            return "In \(days) days"
        default:
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
    }

    @ViewBuilder
    private var cashFlowSnapshot: some View {
        let schedules = snapshot.cashFlowSchedules

        if !schedules.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeader(title: "Next 30 days", detail: "Projected cash flow")
                    NavigationLink {
                        ScheduledTransactionsView(store: store)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                    }
                    .accessibilityLabel("Open cash flow schedules")
                }

                Text("Confirmed balances plus enabled recurring entries. Scheduled items are not included in the ledger until they run.")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                VStack(spacing: 0) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        let current = snapshot.availableBalances[currency]
                            ?? Money(currency: currency, minorUnits: 0)
                        let change = snapshot.scheduledChanges[currency] ?? 0
                        let projected = Money(currency: currency, minorUnits: current.minorUnits + change)

                        if currency != LedgerCurrency.allCases[0] {
                            Divider().overlay(PocketLedgerTheme.divider)
                        }

                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(currency.rawValue)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                                Text("\(schedules.count) scheduled \(schedules.count == 1 ? "entry" : "entries")")
                                    .font(.caption2)
                                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                protectedBalanceText(projected.formatted)
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(projected.minorUnits < 0 ? PocketLedgerTheme.warning : PocketLedgerTheme.textPrimary)
                                protectedBalanceText(change >= 0 ? "+\(Money(currency: currency, minorUnits: change).formatted) scheduled"
                                     : "\(Money(currency: currency, minorUnits: change).formatted) scheduled")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(change >= 0 ? PocketLedgerTheme.income : PocketLedgerTheme.warning)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14)
                .pocketGroupedSurface(cornerRadius: 17)

                if LedgerCurrency.allCases.contains(where: {
                    (snapshot.scheduledChanges[$0] ?? 0) < 0
                }) {
                    Label("Review upcoming outflows before they affect your included balances.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.warning)
                }
            }
        }
    }

    private func snapshotMetric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(value)
                .font(.headline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(13)
        .pocketGroupedSurface(cornerRadius: 17)
    }

    private func monthExpenseRow(currency: LedgerCurrency, total: Int64) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(PocketLedgerTheme.warning.opacity(0.18))
                    .frame(width: 8, height: 8)
                Text("Expenses in \(currency.rawValue)")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }

            Spacer()

            protectedBalanceText(Money(currency: currency, minorUnits: total).formatted)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(PocketLedgerTheme.warning)
        }
        .padding(.vertical, 5)
    }

    private var recentActivity: some View {
        Section {
            if snapshot.recentTransactions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                    Text("Your ledger is ready")
                        .font(.headline)
                    Text("Add your first expense, income, or transfer to see it here.")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Add expense", systemImage: "plus", action: onAddExpense)
                        .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .pocketCard()
                .listRowInsets(
                    EdgeInsets(
                        top: 0,
                        leading: PocketLedgerTheme.screenHorizontalPadding,
                        bottom: 0,
                        trailing: PocketLedgerTheme.screenHorizontalPadding
                    )
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(snapshot.recentTransactions.prefix(5).enumerated()), id: \.element.id) { entry in
                    let transaction = entry.element
                    TransactionRow(
                        transaction: transaction,
                        store: store,
                        onEdit: { presentedSheet = .transaction(transaction) },
                        onDuplicate: { _ = store.duplicateTransaction(id: transaction.id) },
                        onDelete: { transactionDeletion.delete(transaction, in: store) },
                        onSaveTemplate: { transactionToTemplate = transaction },
                        allowsActions: true
                    )
                    .transition(
                        reduceMotion
                            ? .identity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .pocketGroupedListRow(
                        index: entry.offset,
                        count: min(snapshot.recentTransactions.count, 5)
                    )
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent activity")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("See all", action: onShowTransactions)
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketLedgerTheme.accent)
                    .accessibilityLabel("See all transactions")
                    .accessibilityHint("Opens transaction history")
                    .font(.caption.weight(.semibold))
            }
            .textCase(nil)
        }
        .listSectionSeparator(.hidden)
    }

    @ViewBuilder
    private var budgetSnapshot: some View {
        if !snapshot.budgetSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeader(title: "Budget pulse", detail: "This month")
                    NavigationLink {
                        BudgetsView(store: store, security: security)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                    }
                    .accessibilityLabel("Open budgets")
                }

                VStack(spacing: 12) {
                    ForEach(Array(snapshot.budgetSummaries.prefix(3))) { summary in
                        let budget = summary.budget
                        let spent = summary.spent
                        let allowance = summary.allowance
                        let over = summary.isOver
                        let remaining = summary.remaining
                        let projectedOver = summary.isProjectedOver
                        let ratio = summary.ratio

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(summary.categoryPath)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                protectedBalanceText("\(spent.formatted) / \(allowance.formatted)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.textSecondary)
                            }
                            ProgressView(value: ratio)
                                .tint(projectedOver ? PocketLedgerTheme.warning : PocketLedgerTheme.accent)
                            HStack(spacing: 10) {
                                protectedBalanceText(over
                                     ? "Over by \(Money(currency: budget.currency, minorUnits: -remaining).formatted)"
                                     : "Remaining \(Money(currency: budget.currency, minorUnits: remaining).formatted)")
                                    .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.positive)
                                Spacer()
                                protectedBalanceText("Projected \(summary.projected.formatted)")
                                    .foregroundStyle(projectedOver ? PocketLedgerTheme.warning : PocketLedgerTheme.textTertiary)
                            }
                            .font(.caption.weight(.semibold).monospacedDigit())
                        }
                    }
                }
                .padding(14)
                .pocketGroupedSurface(cornerRadius: 17)
            }
        }
    }

    private var storageNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: store.storageAvailable && store.sharedStorageAvailable
                  ? "checkmark.shield.fill"
                  : store.storageAvailable
                  ? "internaldrive.fill"
                  : "exclamationmark.triangle.fill")
            Text(store.storageStatus)
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(store.storageAvailable
                          ? store.sharedStorageAvailable
                          ? PocketLedgerTheme.positive
                          : PocketLedgerTheme.accent
                          : PocketLedgerTheme.warning)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .pocketGlassCapsule(tint: PocketLedgerTheme.accent.opacity(0.08))
    }

    private func refreshSnapshot() {
        snapshot = DashboardSnapshot.make(
            data: store.data,
            index: store.ledgerIndex,
            attentionItems: store.attentionItems
        )
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Text(detail)
                .font(.caption.weight(.medium))
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
    }
}

@MainActor
private struct DashboardCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: DashboardPreferences

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Turn widgets on or off. Tap Edit to drag them into your preferred order.")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .listRowBackground(PocketLedgerTheme.surface)
                }

                Section("Dashboard widgets") {
                    ForEach(preferences.order) { widget in
                        Toggle(isOn: Binding(
                            get: { !preferences.disabledWidgets.contains(widget) },
                            set: { preferences.setEnabled($0, for: widget) }
                        )) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(widget.title)
                                    Text(widget.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                                }
                            } icon: {
                                Image(systemName: widget.systemImage)
                                    .foregroundStyle(PocketLedgerTheme.accent)
                            }
                        }
                        .accessibilityIdentifier("dashboard-widget-\(widget.rawValue)")
                        .listRowBackground(PocketLedgerTheme.surface)
                    }
                    .onMove { source, destination in
                        preferences.move(from: source, to: destination)
                    }
                }

                Section {
                    Button("Reset dashboard", role: .destructive) {
                        preferences.reset()
                    }
                } footer: {
                    Text("Reset restores the default widgets and order.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .background(PocketLedgerTheme.background)
            .navigationTitle("Customize dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .tint(PocketLedgerTheme.accent)
            .foregroundStyle(PocketLedgerTheme.textPrimary)
        }
    }
}

@MainActor
private struct AttentionInboxView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    let onAddExpense: () -> Void

    var body: some View {
        let attentionItems = store.attentionItems

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if attentionItems.isEmpty {
                    emptyState
                } else {
                    Text("Resolve these items to keep balances, budgets, and metrics trustworthy.")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)

                    ForEach(attentionItems) { item in
                        attentionCard(item)
                    }
                }

                if !store.data.attentionState.dismissedIDs.isEmpty {
                    Button("Restore dismissed items", systemImage: "arrow.uturn.backward") {
                        _ = store.restoreDismissedAttention()
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .pocketScreen()
        .navigationTitle("Needs attention")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("needs-attention-inbox")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(PocketLedgerTheme.positive)
            Text("Everything looks clear")
                .font(.headline)
            Text("Pocket Ledger has no unresolved balance, budget, or transaction issues.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .padding(.horizontal, 20)
        .pocketGroupedSurface(cornerRadius: 20)
    }

    private func attentionCard(_ item: FinanceAttentionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(item.severity == .warning ? PocketLedgerTheme.warning : PocketLedgerTheme.accent)
                .frame(width: 38, height: 38)
                .pocketGlassSurface(
                    cornerRadius: 19,
                    tint: (item.severity == .warning ? PocketLedgerTheme.warning : PocketLedgerTheme.accent).opacity(0.14)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Text("\(item.count) \(item.count == 1 ? "item" : "items")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textTertiary)

                NavigationLink {
                    destination(for: item.destination)
                } label: {
                    Label("Review", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .tint(item.severity == .warning ? PocketLedgerTheme.warning : PocketLedgerTheme.accent)
                .padding(.top, 3)
            }

            Spacer(minLength: 0)

            Button {
                _ = store.dismissAttention(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Dismiss \(item.title)")
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func destination(for destination: FinanceAttentionDestination) -> some View {
        switch destination {
        case .uncategorizedTransactions:
            TransactionsView(
                store: store,
                onAddExpense: onAddExpense,
                security: security,
                initialFilter: .uncategorized
            )
        case .transferTransactions:
            TransactionsView(
                store: store,
                onAddExpense: onAddExpense,
                security: security,
                initialFilter: .transfer
            )
        case .scheduledTransactions:
            ScheduledTransactionsView(store: store)
        case .budgets:
            BudgetsView(store: store, security: security)
        }
    }
}
