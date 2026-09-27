import Foundation
import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var store = LedgerStore()
    @StateObject private var security = AppSecurityService()
    @StateObject private var intentSearchRouter = FinanceIntentSearchRouter.shared
    @State private var addAction: AddAction?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var tabBeforeSearch = AppTab.overview
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isShowingSetup = false
    @State private var isShowingImportWizardUITest = false
    @State private var isUnlocked = false
    @SceneStorage("pocketLedger.selectedTab") private var selectedTabRawValue = AppTab.overview.rawValue
    @AppStorage(SetupWizardView.completedKey) private var setupCompleted = false
    @AppStorage(PocketLedgerTheme.appearanceModeKey) private var selectedAppearanceMode = PocketLedgerAppearanceMode.system.rawValue
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            unlockedContent
                .allowsHitTesting(!(security.isPasscodeEnabled && !isUnlocked))

            if security.isPasscodeEnabled && !isUnlocked {
                AppLockView(security: security, isUnlocked: $isUnlocked)
                    .zIndex(1)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                security.refresh()
                store.reload()
                openPendingQuickExpense()
                store.processDueScheduledTransactions()
                let schedules = store.data.scheduledTransactions
                Task {
                    await NotificationService.refreshScheduledTransactionNotifications(
                        schedules: schedules
                    )
                }
            } else if phase == .inactive {
                if security.isPasscodeEnabled && !security.isBiometricPromptActive {
                    isUnlocked = false
                }
            } else if phase == .background {
                areBalancesRevealed = false
                if security.isPasscodeEnabled {
                    isUnlocked = false
                }
            }
        }
        .onChange(of: security.isPasscodeEnabled) { _, enabled in
            isUnlocked = !enabled
        }
        .onChange(of: intentSearchRouter.pendingSearch?.id) { _, _ in
            openPendingIntentSearch()
        }
        .task {
            areBalancesRevealed = false
            openPendingIntentSearch()
            if ProcessInfo.processInfo.arguments.contains("-ImportWizardUITest") {
                isShowingImportWizardUITest = true
                return
            }
            openPendingQuickExpense()
            store.processDueScheduledTransactions()
            await NotificationService.refreshScheduledTransactionNotifications(
                schedules: store.data.scheduledTransactions
            )
            await FinanceIntentIndexing.shared.refresh()
            if !setupCompleted && store.data.accounts.isEmpty && store.data.categories.isEmpty {
                isShowingSetup = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pocketLedgerWatchLedgerDidChange)) { _ in
            store.reload()
        }
        .onOpenURL(perform: handleDeepLink)
        .sheet(isPresented: $isShowingSetup) {
            SetupWizardView(store: store)
        }
        .sheet(isPresented: $isShowingImportWizardUITest) {
            ImportWizardView(store: store, document: importWizardUITestDocument)
                .presentationDetents([.large])
        }
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: {
                let tab = AppTab(rawValue: selectedTabRawValue) ?? .overview
                return tab == .metrics ? .more : tab
            },
            set: { tab in
                guard selectedTabRawValue != tab.rawValue else { return }
                let currentTab = AppTab(rawValue: selectedTabRawValue) ?? .overview
                if tab == .search, currentTab != .search {
                    tabBeforeSearch = currentTab
                } else if tab != .search {
                    isSearchPresented = false
                    isSearchFieldFocused = false
                }
                withAnimation(PocketLedgerMotion.quick(reduceMotion: reduceMotion)) {
                    selectedTabRawValue = tab.rawValue
                }
            }
        )
    }

    private func handleDeepLink(_ url: URL) {
        if url.scheme == "pocketledger", url.host == "add", url.path == "/expense" {
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let amountText = queryItems.first(where: { $0.name == "amount" })?.value ?? ""
            let currency = queryItems.first(where: { $0.name == "currency" })?.value
                .flatMap(LedgerCurrency.init(rawValue:)) ?? .usd
            guard let amount = Money.parse(amountText, currency: currency), amount.minorUnits > 0 else { return }
            let note = queryItems.first(where: { $0.name == "note" })?.value ?? "Quick expense"
            selectedTabBinding.wrappedValue = .transactions
            addAction = .prefilledExpense(id: UUID(), amount: amount, note: note)
            return
        }
        guard let tab = AppTab(url: url) else { return }
        selectedTabBinding.wrappedValue = tab
    }

    private func openPendingQuickExpense() {
        guard let request = FinanceIntentQuickExpenseRequest.consume() else { return }
        selectedTabBinding.wrappedValue = .transactions
        addAction = .prefilledExpense(id: UUID(), amount: request.amount, note: request.note)
    }

    private func openPendingIntentSearch() {
        guard let request = intentSearchRouter.consumePendingSearch() else { return }
        searchText = request.query
        selectedTabBinding.wrappedValue = .search
        isSearchPresented = true
        isSearchFieldFocused = true
    }

    private var unlockedContent: some View {
        TabView(selection: selectedTabBinding) {
            Tab(
                "Home",
                systemImage: AppTab.overview.systemImage,
                value: AppTab.overview
            ) {
                DashboardView(
                    store: store,
                    security: security,
                    onAddExpense: { addAction = .expense },
                    onShowTransactions: { selectedTabBinding.wrappedValue = .transactions },
                    onAddAction: { addAction = $0 }
                )
            }
            .accessibilityIdentifier("tab-overview")

            Tab(value: AppTab.search, role: .search) {
                NavigationStack {
                    GlobalSearchView(store: store, security: security, searchText: $searchText)
                        .searchable(
                            text: $searchText,
                            isPresented: $isSearchPresented,
                            placement: .toolbar,
                            prompt: "Search accounts, transactions, descriptions…"
                        )
                        .searchFocused($isSearchFieldFocused)
                        .toolbar {
                            PocketLedgerToolbar(security: security) {
                                AddTransactionToolbar(store: store, onAction: { addAction = $0 })
                            }
                        }
                }
            }
            .accessibilityIdentifier("tab-search")

            Tab(
                "Transactions",
                systemImage: AppTab.transactions.systemImage,
                value: AppTab.transactions
            ) {
                NavigationStack {
                    TransactionsView(
                        store: store,
                        onAddExpense: { addAction = .expense },
                        onAddAction: { addAction = $0 },
                        security: security
                    )
                }
            }
            .accessibilityIdentifier("tab-transactions")

            Tab(
                "Accounts",
                systemImage: AppTab.accounts.systemImage,
                value: AppTab.accounts
            ) {
                NavigationStack {
                    AccountsView(
                        store: store,
                        security: security,
                        onAddAction: { addAction = $0 }
                    )
                }
            }
            .accessibilityIdentifier("tab-accounts")

            Tab(
                "More",
                systemImage: AppTab.more.systemImage,
                value: AppTab.more
            ) {
                MoreView(
                    store: store,
                    security: security,
                    onAddExpense: { addAction = .expense },
                    onAddAction: { addAction = $0 }
                )
            }
            .accessibilityIdentifier("tab-more")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: selectedTabRawValue) { _, rawValue in
            guard rawValue == AppTab.search.rawValue else { return }
            isSearchPresented = true
            isSearchFieldFocused = true
        }
        .onChange(of: isSearchPresented) { _, isPresented in
            guard !isPresented, selectedTabBinding.wrappedValue == .search else { return }
            selectedTabBinding.wrappedValue = tabBeforeSearch
        }
        .tint(PocketLedgerTheme.accent)
        .preferredColorScheme(
            PocketLedgerAppearanceMode(rawValue: selectedAppearanceMode)?.preferredColorScheme
        )
        .sheet(item: $addAction) { action in
            switch action {
            case .scanBill:
                BillScannerView(store: store)
            case .expense:
                TransactionEditor(store: store, initialKind: .expense)
            case .prefilledExpense(_, let amount, let note):
                TransactionEditor(
                    store: store,
                    initialKind: .expense,
                    initialAmount: amount,
                    initialNote: note
                )
            case .income:
                TransactionEditor(store: store, initialKind: .income)
            case .transfer:
                TransactionEditor(store: store, initialKind: .transfer)
            case .scheduled:
                TransactionEditor(store: store, initialKind: .expense, initialTiming: .scheduled)
            case .template(let templateID):
                if let template = store.data.templates.first(where: { $0.id == templateID }) {
                    TransactionEditor(store: store, template: template)
                } else {
                    EmptyView()
                }
            case .recent(let transactionID):
                if let transaction = store.data.transactions.first(where: { $0.id == transactionID }) {
                    TransactionEditor(store: store, prefilledTransaction: transaction)
                } else {
                    EmptyView()
                }
            }
        }
    }

    private var importWizardUITestDocument: ImportedDocument {
        ImportedDocument(
            fileName: "import-wizard-ui-test.csv",
            format: .delimited,
            tables: [
                ImportedTable(
                    id: "ui-test-rows",
                    name: "Imported rows",
                    columns: ["Date", "Amount", "Account", "Account Type", "Category", "Note"],
                    rows: [
                        ["2026-09-01", "10", "Gold", "Good", "Food", "Gold purchase"],
                        ["2026-09-02", "20", "Silver", "Silver", "Food", "Silver purchase"]
                    ]
                )
            ]
        )
    }

}

enum AddAction: Identifiable {
    case scanBill
    case expense
    case prefilledExpense(id: UUID, amount: Money, note: String)
    case income
    case transfer
    case scheduled
    case template(UUID)
    case recent(UUID)

    var id: String {
        switch self {
        case .scanBill:
            return "scanBill"
        case .expense:
            return "expense"
        case .prefilledExpense(let id, _, _):
            return "prefilled-expense-\(id.uuidString)"
        case .income:
            return "income"
        case .transfer:
            return "transfer"
        case .scheduled:
            return "scheduled"
        case .template(let id):
            return "template-\(id.uuidString)"
        case .recent(let id):
            return "recent-\(id.uuidString)"
        }
    }
}

@MainActor
struct AddTransactionToolbar: ToolbarContent {
    @ObservedObject var store: LedgerStore
    @AppStorage("pocketLedger.recentTemplateIDs") private var recentTemplateIDsValue = ""
    let onAction: (AddAction) -> Void
    var systemImage = "plus"

    private var recentTemplateIDs: [UUID] {
        recentTemplateIDsValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    private var recentTemplates: [LedgerTemplate] {
        recentTemplateIDs.compactMap { id in store.data.templates.first { $0.id == id } }
    }

    private var otherTemplates: [LedgerTemplate] {
        store.data.templates.filter { !recentTemplateIDs.contains($0.id) }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                onAction(.expense)
            } label: {
                Image(systemName: systemImage)
            }
            .accessibilityLabel("Add expense")
            .accessibilityHint("Opens a new expense")
            .accessibilityIdentifier("add-transaction-button")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Add transaction") {
                    Button("Income", systemImage: "arrow.down.left") { onAction(.income) }
                    Button("Transfer", systemImage: "arrow.left.arrow.right") { onAction(.transfer) }
                }

                Section("Other") {
                    Button("Scan bill", systemImage: "doc.text.viewfinder") { onAction(.scanBill) }
                    Button("Scheduled", systemImage: "calendar.badge.clock") { onAction(.scheduled) }
                }

                if !recentTemplates.isEmpty {
                    Section("Recent templates") {
                        ForEach(Array(recentTemplates.prefix(3)), id: \.id) { template in
                            Button(template.name, systemImage: "clock.arrow.circlepath") {
                                useTemplate(template.id)
                            }
                        }
                    }
                }

                if !otherTemplates.isEmpty {
                    Section("Templates") {
                        ForEach(Array(otherTemplates.prefix(3)), id: \.id) { template in
                            Button(template.name, systemImage: "rectangle.stack") {
                                useTemplate(template.id)
                            }
                        }
                    }
                }

                if !store.recentTransactions.isEmpty {
                    Section("Recent") {
                        ForEach(Array(store.recentTransactions.prefix(3)), id: \.id) { transaction in
                            Button(transaction.note, systemImage: "clock.arrow.circlepath") {
                                onAction(.recent(transaction.id))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More transaction actions")
            .accessibilityIdentifier("more-transaction-actions")
        }
    }

    private func useTemplate(_ id: UUID) {
        let recent = ([id] + recentTemplateIDs.filter { $0 != id }).prefix(5)
        recentTemplateIDsValue = recent.map(\.uuidString).joined(separator: ",")
        onAction(.template(id))
    }
}

enum AppTab: String, Hashable {
    case overview
    case search
    case accounts
    case transactions
    case metrics
    case more

    static let tabBarOrder: [AppTab] = [.overview, .transactions, .accounts, .more, .search]

    var title: String {
        switch self {
        case .overview:
            return "Home"
        case .search:
            return "Search"
        case .accounts:
            return "Accounts"
        case .transactions:
            return "Transactions"
        case .metrics:
            return "Metrics"
        case .more:
            return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "house.fill"
        case .search:
            return "magnifyingglass"
        case .accounts:
            return "wallet.pass"
        case .transactions:
            return "list.bullet.rectangle"
        case .metrics:
            return "chart.xyaxis.line"
        case .more:
            return "ellipsis.circle"
        }
    }

    init?(url: URL) {
        guard url.scheme == "pocketledger" else { return nil }
        let destination = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard destination == Self.overview.rawValue
            || destination == Self.accounts.rawValue
            || destination == Self.transactions.rawValue else {
            return nil
        }
        self.init(rawValue: destination)
    }
}
