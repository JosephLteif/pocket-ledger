import Foundation
import SwiftUI

@MainActor
struct MoreView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @ObservedObject private var proAccess = ProEntitlementStore.shared
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

                Section("Pocket Ledger Pro") {
                    ProUpgradeButton(feature: .general) {
                        Label(
                            proAccess.hasProAccess ? "Pro is active" : "Explore Pro",
                            systemImage: proAccess.hasProAccess ? "checkmark.seal.fill" : "sparkles"
                        )
                    }
                    .listRowBackground(PocketLedgerTheme.surface)
                }

                Section("Planning") {
                    NavigationLink {
                        SavingsGoalsView(store: store, security: security)
                    } label: {
                        Label("Savings goals", systemImage: "flag")
                    }
                    .listRowBackground(PocketLedgerTheme.surface)

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
                        ScheduledTransactionsView(store: store, security: security)
                    } label: {
                        Label("Scheduled & subscriptions", systemImage: "calendar.badge.clock")
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
                Section("App version") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
                }
                .listRowBackground(PocketLedgerTheme.surface)
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                AddTransactionToolbar(store: store, onAction: onAddAction)
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
        .toolbar {
            BalanceVisibilityToolbarItem(security: security)
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
    @State private var deletedTransactionsForUndo: [LedgerTransaction] = []
    @State private var transactionDeletionError: String?
    @State private var snapshot = DashboardSnapshot.empty
    @State private var dashboardPreferences = DashboardPreferences.load()
    @State private var isBalanceScopeExpanded = false
    @State private var selectedPhysicalAssetGainAccountID: UUID? = nil
    @State private var selectedPhysicalAssetGainMetal: PreciousMetal? = nil
    @AppStorage(SetupWizardView.checklistKey) private var showFirstWeekChecklist = false
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @AppStorage("pocketLedger.showAllBalanceCurrencies") private var showsAllBalanceCurrencies = false
    @AppStorage(PocketLedgerTheme.appearanceModeKey) private var selectedAppearanceMode = PocketLedgerAppearanceMode.system.rawValue

    var body: some View {
        NavigationStack {
            PocketGlassContainer(spacing: 14) {
                List {
                    dashboardListRow(dashboardDateHeader, top: 12, bottom: 0)
                    if showFirstWeekChecklist && !hasCompletedFirstWeekChecklist {
                        dashboardListRow(firstWeekChecklist)
                    }
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
            .accessibilityIdentifier("dashboard-\(PocketLedgerTheme.colorTheme.rawValue)")
            .preferredColorScheme(
                PocketLedgerAppearanceMode(rawValue: selectedAppearanceMode)?.preferredColorScheme
            )
            .navigationTitle("Pocket Ledger")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                AddTransactionToolbar(store: store, onAction: onAddAction)
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
            .onAppear {
                store.captureDailyPhysicalAssetGainHistory()
                refreshSnapshot()
                if hasCompletedFirstWeekChecklist {
                    showFirstWeekChecklist = false
                }
            }
            .onChange(of: store.ledgerRevision) { _, _ in
                withAnimation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion)) {
                    refreshSnapshot()
                }
                if hasCompletedFirstWeekChecklist {
                    showFirstWeekChecklist = false
                }
            }
            .onChange(of: dashboardPreferences) { _, preferences in preferences.save() }
        }
        .toolbar {
            BalanceVisibilityToolbarItem(security: security)
        }
    }

    private var dashboardDateHeader: some View {
        Text(Date.now, style: .date)
            .font(.subheadline)
            .foregroundStyle(PocketLedgerTheme.textSecondary)
    }

    private var hasCompletedFirstWeekChecklist: Bool {
        !store.data.transactions.isEmpty && !store.data.budgets.isEmpty
    }

    private var firstWeekChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your first week", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(PocketLedgerTheme.textPrimary)
                Spacer()
                Button("Hide") { showFirstWeekChecklist = false }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }

            Text("Your account is ready. A transaction and a budget will help bring your ledger to life.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Label("First account added", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PocketLedgerTheme.positive)

            if store.data.transactions.isEmpty {
                Button(action: onAddExpense) {
                    Label("Add your first transaction", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(PocketLedgerTheme.accent)
            } else {
                Label("First transaction added", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.positive)
            }

            if store.data.budgets.isEmpty {
                if store.activeCategories.isEmpty {
                    NavigationLink {
                        CategoriesView(store: store)
                    } label: {
                        Label("Add a category to start a budget", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(PocketLedgerTheme.accent)
                } else {
                    NavigationLink {
                        BudgetsView(store: store, security: security)
                    } label: {
                        Label("Create your first budget", systemImage: "chart.bar.doc.horizontal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(PocketLedgerTheme.accent)
                }
            } else {
                Label("First budget created", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.positive)
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(PocketLedgerTheme.divider, lineWidth: 1) }
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
        case .physicalAssetGain:
            dashboardListRow(physicalAssetGainWidget)
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
        HStack(alignment: .center, spacing: 12) {
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
            let assetAccounts = snapshot.activeAccounts.filter {
                $0.includeInTotals && $0.currency == currency && ($0.type == .physicalAsset || $0.type == .investment)
            }
            VStack(alignment: .trailing, spacing: 4) {
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

                if !assetAccounts.isEmpty {
                    let gains = assetAccounts.compactMap(store.gainLoss(for:))
                    HStack(spacing: 4) {
                        Text("Gain/loss")
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                        if gains.count == assetAccounts.count {
                            let gain = Money(currency: currency, minorUnits: gains.reduce(0) { $0 + $1.minorUnits })
                            protectedBalanceText(gain.minorUnits > 0 ? "+\(gain.formatted)" : gain.formatted)
                                .foregroundStyle(gain.minorUnits >= 0 ? PocketLedgerTheme.positive : .red)
                        } else {
                            Text("Unavailable")
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(.vertical, 9)
    }

    private var physicalAssetGainAccounts: [Account] {
        store.activeAccounts.filter {
            $0.type == .physicalAsset
                && ($0.tracking?.metalPurchases.isEmpty == false
                    || ($0.tracking?.physicalAssetSubtype == .other && $0.tracking?.investmentEntries.isEmpty == false))
        }
    }

    private func physicalAssetGainMetals(in account: Account) -> [PreciousMetal] {
        PreciousMetal.allCases.filter { metal in
            account.tracking?.metalPurchases.contains { $0.metal == metal } == true
        }
    }

    private var physicalAssetGainWidget: some View {
        let accounts = physicalAssetGainAccounts
        let selectedAccount = accounts.first { $0.id == selectedPhysicalAssetGainAccountID } ?? accounts.first
        let availableMetals = selectedAccount.map { physicalAssetGainMetals(in: $0) } ?? []
        let selectedMetal = selectedPhysicalAssetGainMetal.flatMap { availableMetals.contains($0) ? $0 : nil }
        let showsScopeMenu = accounts.count > 1 || accounts.contains { !physicalAssetGainMetals(in: $0).isEmpty }
        let selectionTitle = selectedAccount.map { account in
            let scope = selectedMetal?.displayName ?? (availableMetals.isEmpty ? nil : "All metals")
            return scope.map { "\(account.name) · \($0)" } ?? account.name
        } ?? ""

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Physical asset gain/loss", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textPrimary)

                Spacer(minLength: 8)
                if let selectedAccount {
                    if showsScopeMenu {
                        Menu {
                            ForEach(accounts) { account in
                                let metals = physicalAssetGainMetals(in: account)
                                Section(account.name) {
                                    if metals.isEmpty {
                                        Button {
                                            selectedPhysicalAssetGainAccountID = account.id
                                            selectedPhysicalAssetGainMetal = nil
                                        } label: {
                                            if account.id == selectedAccount.id {
                                                Label("Account total", systemImage: "checkmark")
                                            } else {
                                                Text("Account total")
                                            }
                                        }
                                    } else {
                                        Button {
                                            selectedPhysicalAssetGainAccountID = account.id
                                            selectedPhysicalAssetGainMetal = nil
                                        } label: {
                                            if account.id == selectedAccount.id && selectedMetal == nil {
                                                Label("All metals", systemImage: "checkmark")
                                            } else {
                                                Text("All metals")
                                            }
                                        }
                                        ForEach(metals) { metal in
                                            Button {
                                                selectedPhysicalAssetGainAccountID = account.id
                                                selectedPhysicalAssetGainMetal = metal
                                            } label: {
                                                if account.id == selectedAccount.id && selectedMetal == metal {
                                                    Label(metal.displayName, systemImage: "checkmark")
                                                } else {
                                                    Text(metal.displayName)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label {
                                Text(selectionTitle)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "chevron.down")
                            }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PocketLedgerTheme.accent)
                        }
                        .accessibilityLabel("Choose physical asset account and metal")
                    } else {
                        Text(selectedAccount.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketLedgerTheme.accent)
                    }
                }
            }

            if let selectedAccount {
                PhysicalAssetGainHistoryChart(
                    account: selectedAccount,
                    areBalancesRevealed: areBalancesRevealed,
                    selectedMetal: $selectedPhysicalAssetGainMetal
                )
            } else {
                Text("Track gold or silver in a physical asset account to see daily gains here.")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
        }
        .padding(20)
        .pocketGroupedSurface(cornerRadius: 22)
        .task { await store.refreshMetalPrices() }
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
            NavigationLink {
                AccountsView(store: store, security: security, onAddAction: onAddAction)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Balance scope")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(PocketLedgerTheme.textPrimary)
                        Text("Account balances by type")
                            .font(.caption)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Balance scope, account balances by type, Open accounts")

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
            NavigationLink {
                LoansView(store: store, security: security)
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Loans")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(PocketLedgerTheme.textPrimary)
                        Text(activeLoans.isEmpty ? "No active loans" : "\(activeLoans.count) active")
                            .font(.caption)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Loans, \(activeLoans.count) active, Open loans")

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
                        systemImage: "list.bullet",
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
                NavigationLink {
                    ScheduledTransactionsView(store: store, security: security)
                } label: {
                    sectionHeader(title: "Upcoming", detail: "Bills & recurring entries")
                }
                .accessibilityLabel("Upcoming, bills and recurring entries, Open scheduled transactions")

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
        HStack(spacing: 12) {
            Image(systemName: schedule.kind == .income ? "arrow.down.left" : "calendar.badge.clock")
                .font(.body.weight(.semibold))
                .foregroundStyle(schedule.kind == .income ? PocketLedgerTheme.income : PocketLedgerTheme.accent)
                .frame(width: 28, height: 28)
                .pocketGlassSurface(cornerRadius: 14, tint: PocketLedgerTheme.accent.opacity(0.14))

            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.note.isEmpty ? schedule.kind.displayName : schedule.note)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(store.transactionSummary(schedule.transactionTemplate))
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
            "\(schedule.note.isEmpty ? schedule.kind.displayName : schedule.note), \(store.transactionSummary(schedule.transactionTemplate)), \(schedule.nextRunDate.formatted(date: .abbreviated, time: .shortened))"
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
                NavigationLink {
                    ScheduledTransactionsView(store: store, security: security)
                } label: {
                    sectionHeader(title: "Next 30 days", detail: "Projected cash flow")
                }
                .accessibilityLabel("Next 30 days, projected cash flow, Open cash flow schedules")

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

            Text(Money(currency: currency, minorUnits: total).formatted)
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
                        onDelete: {
                            if store.deleteTransaction(id: transaction.id) {
                                deletedTransactionsForUndo.append(transaction)
                            } else {
                                transactionDeletionError = store.lastActionStatus ?? "The transaction could not be deleted."
                            }
                        },
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
                NavigationLink {
                    BudgetsView(store: store, security: security)
                } label: {
                    sectionHeader(title: "Budget pulse", detail: "This month")
                }
                .accessibilityLabel("Budget pulse, this month, Open budgets")

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
                                Text("\(spent.formatted) / \(allowance.formatted)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.textSecondary)
                            }
                            ProgressView(value: ratio)
                                .tint(projectedOver ? PocketLedgerTheme.warning : PocketLedgerTheme.accent)
                            HStack(spacing: 10) {
                                Text(over
                                     ? "Over by \(Money(currency: budget.currency, minorUnits: -remaining).formatted)"
                                     : "Remaining \(Money(currency: budget.currency, minorUnits: remaining).formatted)")
                                    .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.positive)
                                Spacer()
                                Text("Projected \(summary.projected.formatted)")
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
                .foregroundStyle(PocketLedgerTheme.textPrimary)
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
            ScheduledTransactionsView(store: store, security: security)
        case .budgets:
            BudgetsView(store: store, security: security)
        }
    }
}
