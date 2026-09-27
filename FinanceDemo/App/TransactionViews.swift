import Foundation
import SwiftUI

enum TransactionFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case expense = "Expenses"
    case income = "Income"
    case transfer = "Transfers"
    case uncategorized = "Uncategorized"

    var id: String { rawValue }

    var kind: TransactionKind? {
        switch self {
        case .all:
            return nil
        case .expense:
            return .expense
        case .income:
            return .income
        case .transfer:
            return .transfer
        case .uncategorized:
            return .expense
        }
    }
}

enum TransactionPeriod: String, CaseIterable, Identifiable, Hashable {
    case all = "All time"
    case thisMonth = "This month"
    case lastMonth = "Last month"
    case thisYear = "This year"
    case custom = "Custom range"

    var id: String { rawValue }

    func includes(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: .now)?.contains(date) ?? true
        case .lastMonth:
            guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: .now) else {
                return true
            }
            return calendar.dateInterval(of: .month, for: lastMonth)?.contains(date) ?? true
        case .thisYear:
            return calendar.dateInterval(of: .year, for: .now)?.contains(date) ?? true
        case .custom:
            return true
        }
    }
}

enum TransactionQuickFilter: String, CaseIterable, Identifiable {
    case none
    case thisMonth
    case uncategorized
    case needsReceipt
    case cash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "All transactions"
        case .thisMonth:
            return "This month"
        case .uncategorized:
            return "Uncategorized"
        case .needsReceipt:
            return "Needs receipt"
        case .cash:
            return "Cash"
        }
    }
}

struct TransactionDay: Identifiable {
    let date: Date
    let transactions: [LedgerTransaction]

    var id: Date { date }
}

struct TransactionListSnapshot {
    let filteredTransactions: [LedgerTransaction]
    let pageTransactions: [LedgerTransaction]
    let groupedTransactions: [TransactionDay]
    let pageCount: Int
    let displayedPage: Int
    let expenseTotals: [LedgerCurrency: Int64]
    let incomeTotals: [LedgerCurrency: Int64]

    static var empty: TransactionListSnapshot {
        TransactionListSnapshot(
            filteredTransactions: [],
            pageTransactions: [],
            groupedTransactions: [],
            pageCount: 1,
            displayedPage: 0,
            expenseTotals: [:],
            incomeTotals: [:]
        )
    }

    static func make(
        index: LedgerIndex,
        filter: TransactionFilter,
        period: TransactionPeriod,
        quickFilter: TransactionQuickFilter,
        searchText: String,
        customStartDate: Date,
        customEndDate: Date,
        page: Int,
        pageSize: Int,
        categoryID: UUID? = nil,
        includesCategoryDescendants: Bool = true,
        accountID: UUID? = nil,
        reportingCurrency: LedgerCurrency? = nil,
        calendar: Calendar = .current
    ) -> TransactionListSnapshot {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredTransactions = index.sortedTransactions.filter { transaction in
            let matchesKind: Bool
            if filter == .uncategorized {
                matchesKind = transaction.kind == .expense && transaction.categoryID == nil
            } else {
                matchesKind = filter.kind.map { transaction.kind == $0 } ?? true
            }
            guard matchesKind else { return false }

            let matchesPeriod: Bool
            if period == .custom {
                let start = calendar.startOfDay(for: customStartDate)
                let end = calendar.date(
                    byAdding: DateComponents(day: 1),
                    to: calendar.startOfDay(for: customEndDate)
                ) ?? customEndDate
                matchesPeriod = transaction.date >= start && transaction.date < end
            } else {
                matchesPeriod = period.includes(transaction.date, calendar: calendar)
            }
            guard matchesPeriod else { return false }

            if let categoryID {
                guard let transactionCategoryID = transaction.categoryID else { return false }
                let ancestors = index.categoryAncestorsByID[transactionCategoryID] ?? [transactionCategoryID]
                let matchesCategory = includesCategoryDescendants
                    ? ancestors.contains(categoryID)
                    : transactionCategoryID == categoryID
                guard matchesCategory else { return false }
            }

            if let accountID {
                let movements = transaction.outflows + transaction.inflows
                guard movements.contains(where: { $0.accountID == accountID }) else { return false }

                if let reportingCurrency {
                    let accountOutflows = transaction.outflows.filter { $0.accountID == accountID }
                    let accountInflows = transaction.inflows.filter { $0.accountID == accountID }
                    let accountNet = index.movementTotal(
                        accountOutflows,
                        currency: reportingCurrency,
                        exchangeRate: transaction.exchangeRate
                    ) - index.movementTotal(
                        accountInflows,
                        currency: reportingCurrency,
                        exchangeRate: transaction.exchangeRate
                    )
                    guard accountNet > 0 else { return false }
                }
            }

            if let reportingCurrency, transaction.kind == .expense {
                guard index.netExpenseAmount(transaction, currency: reportingCurrency) > 0 else { return false }
            }

            switch quickFilter {
            case .none, .thisMonth, .uncategorized:
                break
            case .needsReceipt:
                guard transaction.attachmentIDs.isEmpty else { return false }
            case .cash:
                guard (transaction.outflows + transaction.inflows).contains(where: {
                    index.account(with: $0.accountID)?.type == .cash
                }) else { return false }
            }

            guard !query.isEmpty else { return true }
            return FinanceSearch.matches(transaction, query: query, index: index)
        }

        var expenseTotals: [LedgerCurrency: Int64] = [:]
        for transaction in filteredTransactions where transaction.kind == .expense {
            for currency in reportingCurrency.map({ [$0] }) ?? LedgerCurrency.allCases {
                expenseTotals[currency, default: 0] += index.netExpenseAmount(
                    transaction,
                    currency: currency
                )
            }
        }

        var incomeTotals: [LedgerCurrency: Int64] = [:]
        for transaction in filteredTransactions where transaction.kind == .income {
            for currency in LedgerCurrency.allCases {
                incomeTotals[currency, default: 0] += index.movementTotal(
                    transaction.inflows,
                    currency: currency,
                    exchangeRate: transaction.exchangeRate
                )
            }
        }

        return TransactionListSnapshot(
            filteredTransactions: filteredTransactions,
            pageTransactions: [],
            groupedTransactions: [],
            pageCount: 1,
            displayedPage: 0,
            expenseTotals: expenseTotals,
            incomeTotals: incomeTotals
        ).showingPage(page, pageSize: pageSize, calendar: calendar)
    }

    func showingPage(
        _ page: Int,
        pageSize: Int,
        calendar: Calendar = .current
    ) -> TransactionListSnapshot {
        let pageCount = max(1, (filteredTransactions.count + pageSize - 1) / pageSize)
        let displayedPage = min(page, pageCount - 1)
        let pageStart = displayedPage * pageSize
        let pageTransactions = Array(filteredTransactions.dropFirst(pageStart).prefix(pageSize))
        let grouped = Dictionary(grouping: pageTransactions) {
            calendar.startOfDay(for: $0.date)
        }
        let groupedTransactions = grouped.keys.sorted(by: >).map { date in
            TransactionDay(date: date, transactions: grouped[date] ?? [])
        }

        return TransactionListSnapshot(
            filteredTransactions: filteredTransactions,
            pageTransactions: pageTransactions,
            groupedTransactions: groupedTransactions,
            pageCount: pageCount,
            displayedPage: displayedPage,
            expenseTotals: expenseTotals,
            incomeTotals: incomeTotals
        )
    }
}

@MainActor
struct TransactionsView: View {
    private static let lastQuickFilterKey = "pocketLedger.lastTransactionQuickFilter"

    @ObservedObject var store: LedgerStore
    let onAddExpense: () -> Void
    private let onAddAction: ((AddAction) -> Void)?
    private let security: AppSecurityService
    @State private var selectedFilter: TransactionFilter
    @State private var selectedPeriod: TransactionPeriod
    @State private var selectedQuickFilter: TransactionQuickFilter
    @State private var searchText: String
    @State private var customStartDate: Date
    @State private var customEndDate: Date
    @State private var transactionPage = 0
    @State private var editingTransaction: LedgerTransaction?
    @State private var transactionToTemplate: LedgerTransaction?
    @State private var isPresentingBillScanner = false
    @State private var isShowingFilters = false
    @State private var isSelectingTransactions = false
    @State private var selectedTransactionIDs: Set<UUID> = []
    @State private var isShowingBulkDeleteConfirmation = false
    @State private var deletedTransactionsForUndo: [LedgerTransaction] = []
    @State private var transactionDeletionError: String?
    @State private var listSnapshot = TransactionListSnapshot.empty
    @State private var drilldownCategoryID: UUID?
    @State private var drilldownIncludesCategoryDescendants = true
    @State private var drilldownAccountID: UUID?
    @State private var drilldownReportingCurrency: LedgerCurrency?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    private let transactionsPerPage = 25

    init(
        store: LedgerStore,
        onAddExpense: @escaping () -> Void = {},
        onAddAction: ((AddAction) -> Void)? = nil,
        security: AppSecurityService,
        initialFilter: TransactionFilter = .all,
        initialPeriod: TransactionPeriod = .all,
        initialSearch: String = "",
        initialCategoryID: UUID? = nil,
        initialCategoryIncludesDescendants: Bool = true,
        initialAccountID: UUID? = nil,
        initialReportingCurrency: LedgerCurrency? = nil,
        initialCustomStartDate: Date? = nil,
        initialCustomEndDate: Date? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.onAddExpense = onAddExpense
        self.onAddAction = onAddAction
        self.security = security
        _selectedFilter = State(initialValue: initialFilter)
        _selectedPeriod = State(initialValue: initialPeriod)
        _drilldownCategoryID = State(initialValue: initialCategoryID)
        _drilldownIncludesCategoryDescendants = State(initialValue: initialCategoryIncludesDescendants)
        _drilldownAccountID = State(initialValue: initialAccountID)
        _drilldownReportingCurrency = State(initialValue: initialReportingCurrency)
        let hasExplicitContext = initialFilter != .all || initialPeriod != .all || !initialSearch.isEmpty
            || initialCategoryID != nil || initialAccountID != nil || initialReportingCurrency != nil
        let persistedQuickFilter = TransactionQuickFilter(
            rawValue: UserDefaults.standard.string(forKey: Self.lastQuickFilterKey) ?? ""
        ) ?? .none
        _selectedQuickFilter = State(
            initialValue: initialFilter == .uncategorized
                ? .uncategorized
                : hasExplicitContext ? .none : persistedQuickFilter
        )
        _searchText = State(initialValue: initialSearch)
        let calendar = Calendar.current
        let start = initialCustomStartDate ?? calendar.date(byAdding: .day, value: -30, to: .now) ?? .now
        _customStartDate = State(initialValue: start)
        _customEndDate = State(initialValue: initialCustomEndDate ?? .now)
    }

    var body: some View {
        List {
            screenSubtitle
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 2, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if isSelectingTransactions {
                selectionToolbar
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            filtersButton
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            transactionsSummary
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if listSnapshot.filteredTransactions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.title2)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                    Text(store.data.transactions.isEmpty ? "No transactions yet" : "No matching transactions")
                        .font(.headline)
                    Text(store.data.transactions.isEmpty
                        ? "Start with a quick expense from the plus button."
                        : "Try changing your filters or search.")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 38)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if store.data.transactions.isEmpty {
                    Button("Add expense", systemImage: "plus", action: onAddExpense)
                        .buttonStyle(.glassProminent)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Button("Clear filters and search", systemImage: "xmark.circle") {
                        clearFiltersAndSearch()
                    }
                    .buttonStyle(.bordered)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                ForEach(listSnapshot.groupedTransactions) { day in
                    Section {
                        ForEach(Array(day.transactions.enumerated()), id: \.element.id) { entry in
                            transactionListRow(
                                for: entry.element,
                                index: entry.offset,
                                count: day.transactions.count
                            )
                        }
                    } header: {
                        dayHeader(day)
                    }
                    .textCase(nil)
                    .listSectionSeparator(.hidden)
                }

                transactionPagination
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 24, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .pocketScreen()
        .transactionActionAlert(message: $transactionDeletionError)
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItemGroup(placement: .primaryAction) {
                    if isSelectingTransactions {
                        Button("Done") {
                            isSelectingTransactions = false
                            selectedTransactionIDs.removeAll()
                        }
                    } else {
                        Button {
                            isSelectingTransactions = true
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel("Select transactions")
                        .accessibilityIdentifier("select-transactions")
                    }
                }
                if let onAddAction {
                    AddTransactionToolbar(store: store, onAction: onAddAction)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresentingBillScanner = true
                        } label: {
                            Image(systemName: "doc.viewfinder")
                        }
                        .accessibilityLabel("Scan bill")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !deletedTransactionsForUndo.isEmpty {
                undoBanner(for: deletedTransactionsForUndo)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear(perform: refreshListSnapshot)
        .onChange(of: selectedFilter) { _, _ in
            transactionPage = 0
            refreshListSnapshot()
        }
        .onChange(of: selectedPeriod) { _, _ in
            transactionPage = 0
            refreshListSnapshot()
        }
        .onChange(of: customStartDate) { _, _ in
            if customStartDate > customEndDate {
                customEndDate = customStartDate
            }
            transactionPage = 0
            refreshListSnapshot()
        }
        .onChange(of: customEndDate) { _, _ in
            if customEndDate < customStartDate {
                customStartDate = customEndDate
            }
            transactionPage = 0
            refreshListSnapshot()
        }
        .onChange(of: selectedQuickFilter) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.lastQuickFilterKey)
            transactionPage = 0
            refreshListSnapshot()
        }
        .onChange(of: searchText) { _, _ in
            transactionPage = 0
            refreshListSnapshot()
        }
        .onChange(of: transactionPage) { _, _ in refreshListPage() }
        .onChange(of: store.ledgerRevision) { _, _ in
            refreshListSnapshot()
            transactionPage = listSnapshot.displayedPage
        }
        .sheet(isPresented: $isPresentingBillScanner) {
            BillScannerView(store: store)
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionEditor(store: store, transaction: transaction)
        }
        .sheet(item: $transactionToTemplate) { transaction in
            TemplateNameEditor(store: store, transaction: transaction)
        }
    }

    private var activeFilterSummary: String {
        let kind = selectedQuickFilter != .none && selectedQuickFilter != .thisMonth
            ? selectedQuickFilter.title
            : selectedFilter.rawValue
        let period = selectedPeriod == .custom
            ? "\(customStartDate.formatted(date: .abbreviated, time: .omitted))–\(customEndDate.formatted(date: .abbreviated, time: .omitted))"
            : selectedPeriod.rawValue
        return "\(kind) · \(period)"
    }

    private var filtersButton: some View {
        Button {
            isShowingFilters = true
        } label: {
            HStack(spacing: 10) {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(activeFilterSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .pocketGlassSurface(cornerRadius: 13)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transaction-filters")
        .sheet(isPresented: $isShowingFilters) {
            NavigationStack {
                Form {
                    Section("Type") {
                        Picker("Transactions", selection: $selectedFilter) {
                            ForEach(TransactionFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section("Date range") {
                        Picker("Period", selection: $selectedPeriod) {
                            ForEach(TransactionPeriod.allCases) { period in
                                Text(period.rawValue).tag(period)
                            }
                        }

                        if selectedPeriod == .custom {
                            DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                            DatePicker("To", selection: $customEndDate, displayedComponents: .date)
                        }
                    }

                    Section("Saved filter") {
                        Menu {
                            ForEach(TransactionQuickFilter.allCases) { filter in
                                Button {
                                    applyQuickFilter(filter)
                                } label: {
                                    if selectedQuickFilter == filter {
                                        Label(filter.title, systemImage: "checkmark")
                                    } else {
                                        Text(filter.title)
                                    }
                                }
                            }
                        } label: {
                            Label("Saved filter: \(selectedQuickFilter.title)", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityIdentifier("transaction-saved-filter")
                    }
                }
                .pocketListSurface()
                .navigationTitle("Filters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingFilters = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func transactionListRow(
        for transaction: LedgerTransaction,
        index: Int,
        count: Int
    ) -> some View {
        transactionRow(for: transaction)
            .listRowInsets(
                EdgeInsets(
                    top: 0,
                    leading: PocketLedgerTheme.screenHorizontalPadding * 2,
                    bottom: 0,
                    trailing: PocketLedgerTheme.screenHorizontalPadding * 2
                )
            )
            .listRowBackground(
                ledgerGroupedRowBackground(isFirst: index == 0, isLast: index == count - 1)
            )
            .listRowSeparatorTint(PocketLedgerTheme.divider)
            .listRowSeparator(index == count - 1 ? .hidden : .visible, edges: .bottom)
    }

    private func transactionRow(for transaction: LedgerTransaction) -> some View {
        TransactionRow(
            transaction: transaction,
            store: store,
            onEdit: {
                if isSelectingTransactions {
                    toggleSelection(for: transaction)
                } else {
                    editingTransaction = transaction
                }
            },
            onDuplicate: { _ = store.duplicateTransaction(id: transaction.id) },
            onDelete: {
                if store.deleteTransaction(id: transaction.id) {
                    deletedTransactionsForUndo = [transaction]
                } else {
                    transactionDeletionError = store.lastActionStatus ?? "The transaction could not be deleted."
                }
            },
            onSaveTemplate: { transactionToTemplate = transaction },
            allowsActions: !isSelectingTransactions,
            isSelectionMode: isSelectingTransactions,
            isSelected: selectedTransactionIDs.contains(transaction.id),
            onToggleSelection: { toggleSelection(for: transaction) },
            reportingCurrency: drilldownReportingCurrency
        )
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            Text("\(selectedTransactionIDs.count) selected")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            Spacer()

            Menu {
                Button("Remove category", systemImage: "tag.slash") {
                    applyBulkCategory(nil)
                }
                ForEach(store.activeCategories) { category in
                    Button(store.categoryPath(for: category.id), systemImage: category.systemImage) {
                        applyBulkCategory(category.id)
                    }
                }
            } label: {
                Label("Category", systemImage: "tag")
            }
            .disabled(selectedTransactionIDs.isEmpty)

            Menu {
                ForEach(store.activeAccounts) { account in
                    Button("\(account.name) · \(account.currency.rawValue)", systemImage: account.type.systemImage) {
                        applyBulkAccount(account.id)
                    }
                }
            } label: {
                Label("Account", systemImage: "wallet.pass")
            }
            .disabled(selectedTransactionIDs.isEmpty)

            Button {
                isShowingBulkDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .tint(PocketLedgerTheme.warning)
            .disabled(selectedTransactionIDs.isEmpty)
            .accessibilityLabel("Delete selected transactions")
        }
        .padding(12)
        .pocketGlassSurface(cornerRadius: 16, tint: PocketLedgerTheme.accent.opacity(0.08))
        .confirmationDialog(
            "Delete selected transactions?",
            isPresented: $isShowingBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedTransactionIDs.count) transactions", role: .destructive) {
                let selected = store.data.transactions.filter {
                    selectedTransactionIDs.contains($0.id)
                }
                if store.deleteTransactions(ids: selectedTransactionIDs) {
                    deletedTransactionsForUndo = selected
                    selectedTransactionIDs.removeAll()
                    isSelectingTransactions = false
                } else {
                    transactionDeletionError = store.lastActionStatus ?? "The selected transactions could not be deleted."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can be undone from the message at the bottom of the screen.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transaction selection tools")
        .accessibilityIdentifier("transaction-selection-toolbar")
    }

    private func undoBanner(for transactions: [LedgerTransaction]) -> some View {
        TransactionUndoBanner(
            transactions: transactions,
            onUndo: {
                if store.restoreTransactions(transactions) {
                    deletedTransactionsForUndo.removeAll()
                } else {
                    transactionDeletionError = store.lastActionStatus ?? "The transaction could not be restored."
                }
            },
            onDismiss: { deletedTransactionsForUndo.removeAll() }
        )
    }

    private var screenSubtitle: some View {
        let subtitle: String
        if let drilldownCategoryID {
            let currency = drilldownReportingCurrency.map { " · \($0.rawValue)" } ?? ""
            subtitle = "Category · \(store.categoryPath(for: drilldownCategoryID))\(currency)"
        } else if let drilldownAccountID {
            let accountName = store.account(with: drilldownAccountID)?.name ?? "Account"
            let currency = drilldownReportingCurrency.map { " · \($0.rawValue)" } ?? ""
            subtitle = "Account · \(accountName)\(currency)"
        } else {
            subtitle = "Every inflow and outflow, in one place"
        }
        return Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(PocketLedgerTheme.textSecondary)
    }

    private func toggleSelection(for transaction: LedgerTransaction) {
        if selectedTransactionIDs.contains(transaction.id) {
            selectedTransactionIDs.remove(transaction.id)
        } else {
            selectedTransactionIDs.insert(transaction.id)
        }
    }

    private func applyBulkCategory(_ categoryID: UUID?) {
        guard !selectedTransactionIDs.isEmpty else { return }
        if store.updateTransactionCategories(ids: selectedTransactionIDs, categoryID: categoryID) {
            selectedTransactionIDs.removeAll()
            isSelectingTransactions = false
        }
    }

    private func applyBulkAccount(_ accountID: UUID) {
        guard !selectedTransactionIDs.isEmpty else { return }
        if store.updateSingleAccountTransactions(ids: selectedTransactionIDs, accountID: accountID) {
            selectedTransactionIDs.removeAll()
            isSelectingTransactions = false
        }
    }

    private func applyQuickFilter(_ filter: TransactionQuickFilter) {
        selectedQuickFilter = filter
        switch filter {
        case .none:
            selectedFilter = .all
        case .thisMonth:
            selectedFilter = .all
            selectedPeriod = .thisMonth
        case .uncategorized:
            selectedFilter = .uncategorized
        case .needsReceipt, .cash:
            selectedFilter = .all
        }
        transactionPage = 0
    }

    private func refreshListSnapshot() {
        listSnapshot = TransactionListSnapshot.make(
            index: store.ledgerIndex,
            filter: selectedFilter,
            period: selectedPeriod,
            quickFilter: selectedQuickFilter,
            searchText: searchText,
            customStartDate: customStartDate,
            customEndDate: customEndDate,
            page: transactionPage,
            pageSize: transactionsPerPage,
            categoryID: drilldownCategoryID,
            includesCategoryDescendants: drilldownIncludesCategoryDescendants,
            accountID: drilldownAccountID,
            reportingCurrency: drilldownReportingCurrency
        )
    }

    private func refreshListPage() {
        listSnapshot = listSnapshot.showingPage(
            transactionPage,
            pageSize: transactionsPerPage
        )
    }

    private func clearFiltersAndSearch() {
        selectedFilter = .all
        selectedPeriod = .all
        selectedQuickFilter = .none
        searchText = ""
        drilldownCategoryID = nil
        drilldownIncludesCategoryDescendants = true
        drilldownAccountID = nil
        drilldownReportingCurrency = nil
        customStartDate = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        customEndDate = .now
        transactionPage = 0
        refreshListSnapshot()
    }

    @ViewBuilder
    private var transactionPagination: some View {
        if listSnapshot.pageCount > 1 {
            HStack(spacing: 16) {
                Button {
                    transactionPage = max(0, listSnapshot.displayedPage - 1)
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(listSnapshot.displayedPage == 0)

                Text("Page \(listSnapshot.displayedPage + 1) of \(listSnapshot.pageCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                Button {
                    transactionPage = min(listSnapshot.pageCount - 1, listSnapshot.displayedPage + 1)
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(listSnapshot.displayedPage == listSnapshot.pageCount - 1)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    private var transactionsSummary: some View {
        let totals: [(String, [LedgerCurrency: Int64], Color)]
        switch selectedFilter {
        case .income:
            totals = [("received", listSnapshot.incomeTotals, PocketLedgerTheme.income)]
        case .transfer:
            totals = []
        case .all:
            totals = [
                ("spent", listSnapshot.expenseTotals, PocketLedgerTheme.warning),
                ("received", listSnapshot.incomeTotals, PocketLedgerTheme.income)
            ]
        case .expense, .uncategorized:
            totals = [("spent", listSnapshot.expenseTotals, PocketLedgerTheme.warning)]
        }

        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedPeriod.rawValue)
                        .font(.headline)
                    Text("Filtered overview")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }

                Spacer()

                Text("\(listSnapshot.filteredTransactions.count) \(listSnapshot.filteredTransactions.count == 1 ? "transaction" : "transactions")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }

            if selectedFilter == .transfer {
                Text("Transfers move money between accounts and are excluded from income and expense totals.")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    ForEach(totals.indices, id: \.self) { totalIndex in
                        let total = totals[totalIndex]
                    ForEach(drilldownReportingCurrency.map { [$0] } ?? LedgerCurrency.allCases) { currency in
                            transactionSummaryMetric(
                                title: "\(currency.rawValue) \(total.0)",
                                value: Money(currency: currency, minorUnits: total.1[currency] ?? 0).formatted,
                                tint: total.2
                            )
                        }
                    }
                }
            }
        }
        .pocketCard()
    }

    private func transactionSummaryMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
            ProtectedAmountText(value: value, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .pocketGroupedSurface(cornerRadius: 14)
    }

    private func dayHeader(_ day: TransactionDay) -> some View {
        HStack(spacing: 11) {
            VStack(spacing: 0) {
                Text(day.date.formatted(.dateTime.day()))
                    .font(.title3.weight(.bold))
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
            .frame(width: 46, height: 46)
            .pocketGlassSurface(cornerRadius: 13, tint: PocketLedgerTheme.surfaceElevated.opacity(0.22))

            VStack(alignment: .leading, spacing: 2) {
                Text(day.date, style: .date)
                    .font(.subheadline.weight(.semibold))
                Text("\(day.transactions.count) \(day.transactions.count == 1 ? "transaction" : "transactions")")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }

            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

struct TransactionUndoBanner: View {
    let transactions: [LedgerTransaction]
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(PocketLedgerTheme.warning)
            Text(transactions.count == 1
                 ? "Deleted \(transactions[0].note.isEmpty ? "transaction" : transactions[0].note)"
                 : "Deleted \(transactions.count) transactions")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.bold))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Dismiss undo message")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .pocketGlassCapsule(tint: PocketLedgerTheme.warning.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transaction deleted")
    }
}

private struct TransactionActionAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            "Couldn't update transaction",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "The transaction could not be updated.")
        }
    }
}

extension View {
    func transactionActionAlert(message: Binding<String?>) -> some View {
        modifier(TransactionActionAlert(message: message))
    }
}

@MainActor
struct TransactionRow: View {
    let transaction: LedgerTransaction
    @ObservedObject var store: LedgerStore
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingLoanDetails = false
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeStartOffset: CGFloat = 0
    @State private var isTrackingHorizontalSwipe = false
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onSaveTemplate: () -> Void
    let onOpen: (() -> Void)?
    let subtitleOverride: String?
    let amountOverride: String?
    let amountColorOverride: Color?
    let usesScrollSwipeActions: Bool
    let allowsActions: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let reportingCurrency: LedgerCurrency?
    let accountContext: Account?

    init(
        transaction: LedgerTransaction,
        store: LedgerStore,
        onEdit: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSaveTemplate: @escaping () -> Void,
        allowsActions: Bool,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onToggleSelection: @escaping () -> Void = {},
        onOpen: (() -> Void)? = nil,
        subtitleOverride: String? = nil,
        amountOverride: String? = nil,
        amountColorOverride: Color? = nil,
        usesScrollSwipeActions: Bool = false,
        reportingCurrency: LedgerCurrency? = nil,
        accountContext: Account? = nil
    ) {
        self.transaction = transaction
        self.store = store
        self.onEdit = onEdit
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onSaveTemplate = onSaveTemplate
        self.onOpen = onOpen
        self.subtitleOverride = subtitleOverride
        self.amountOverride = amountOverride
        self.amountColorOverride = amountColorOverride
        self.usesScrollSwipeActions = usesScrollSwipeActions
        self.reportingCurrency = reportingCurrency
        self.accountContext = accountContext
        self.allowsActions = allowsActions
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
    }

    var body: some View {
        if usesCustomScrollSwipeFallback {
            rowWithActions
                .simultaneousGesture(customSwipeGesture)
        } else {
            rowButton
        }
    }

    private var rowWithActions: some View {
        ZStack {
            scrollSwipeActions
            rowButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    private var rowButton: some View {
        Button(action: activateRow) {
            rowContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: usesCustomScrollSwipeFallback ? swipeOffset : 0)
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(transaction.note), \(displaySubtitle), \(areBalancesRevealed ? displayAmountText : "Hidden amount")"
        )
        .accessibilityHint(isSelectionMode && canSelectTransaction
            ? "Toggles transaction selection"
            : transaction.loanID != nil
                ? "Opens loan details"
                : "Opens transaction details")
        .contextMenu {
            if canEditTransaction {
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                Button("Save as template", systemImage: "rectangle.stack.badge.plus", action: onSaveTemplate)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canEditTransaction {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(.red, in: Circle())
                }
                .tint(.red)
                .accessibilityLabel("Delete")
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(.yellow, in: Circle())
                }
                .tint(.yellow)
                .accessibilityLabel("Edit")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canEditTransaction {
                Button(action: onDuplicate) {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(PocketLedgerTheme.accent, in: Circle())
                }
                .tint(PocketLedgerTheme.accent)
                .accessibilityLabel("Duplicate")
                Button(action: onSaveTemplate) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(PocketLedgerTheme.positive, in: Circle())
                }
                .tint(PocketLedgerTheme.positive)
                .accessibilityLabel("Template")
            }
        }
        .confirmationDialog(
            "Delete transaction?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(transaction.note)
        }
        .sheet(isPresented: $isShowingLoanDetails) {
            if let loanID = transaction.loanID {
                NavigationStack {
                    LoanDetailView(store: store, loanID: loanID, showsCloseButton: true)
                }
            }
        }
    }

    private var usesCustomScrollSwipeFallback: Bool {
        guard usesScrollSwipeActions && canEditTransaction else { return false }
        if #available(iOS 27, *) { return false }
        return true
    }

    private var scrollSwipeActions: some View {
        HStack(spacing: 0) {
            if isLeadingSwipeActive {
                scrollSwipeAction("Duplicate", systemImage: "plus.square.on.square", tint: PocketLedgerTheme.accent, action: onDuplicate)
                scrollSwipeAction("Template", systemImage: "rectangle.stack.badge.plus", tint: PocketLedgerTheme.positive, action: onSaveTemplate)
            }

            Spacer(minLength: 0)

            if isTrailingSwipeActive {
                scrollSwipeAction("Delete", systemImage: "trash", tint: .red) {
                    isShowingDeleteConfirmation = true
                }
                scrollSwipeAction(
                    "Edit",
                    systemImage: "pencil",
                    tint: .yellow,
                    iconColor: .black,
                    action: onEdit
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(swipeOffset == 0)
    }

    private var isLeadingSwipeActive: Bool {
        layoutDirection == .leftToRight ? swipeOffset > 0 : swipeOffset < 0
    }

    private var isTrailingSwipeActive: Bool {
        layoutDirection == .leftToRight ? swipeOffset < 0 : swipeOffset > 0
    }

    private func scrollSwipeAction(
        _ title: String,
        systemImage: String,
        tint: Color,
        iconColor: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            closeSwipeActions()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 48, height: 48)
                    .background(tint, in: Circle())
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
            .frame(width: 72)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var customSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if !isTrackingHorizontalSwipe {
                    isTrackingHorizontalSwipe = true
                    swipeStartOffset = swipeOffset
                }
                swipeOffset = min(144, max(-144, swipeStartOffset + value.translation.width))
            }
            .onEnded { value in
                guard isTrackingHorizontalSwipe else { return }
                isTrackingHorizontalSwipe = false
                let finalOffset = min(144, max(-144, swipeStartOffset + value.translation.width))
                withAnimation(.snappy) {
                    swipeOffset = abs(finalOffset) >= 72 ? (finalOffset < 0 ? -144 : 144) : 0
                }
                swipeStartOffset = swipeOffset
            }
    }

    private func activateRow() {
        if usesCustomScrollSwipeFallback && swipeOffset != 0 {
            closeSwipeActions()
            return
        }
        if isSelectionMode && canSelectTransaction {
            onToggleSelection()
        } else if !isSelectionMode, transaction.loanID != nil {
            isShowingLoanDetails = true
        } else if !isSelectionMode, transaction.loanID == nil {
            (onOpen ?? onEdit)()
        }
    }

    private func closeSwipeActions() {
        withAnimation(.snappy) {
            swipeOffset = 0
        }
        swipeStartOffset = 0
        isTrackingHorizontalSwipe = false
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isSelectionMode && canSelectTransaction {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? PocketLedgerTheme.accent : PocketLedgerTheme.textTertiary)
                    .accessibilityHidden(true)
            }

            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 38, height: 38)
                .background(accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.note)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)

                if let amountDue = transaction.amountDue {
                    ProtectedAmountText(
                        value: "Bill total · \(amountDue.formatted)",
                        isRevealed: areBalancesRevealed
                    )
                        .font(.caption2)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                        .lineLimit(1)
                }

                if let exchangeRate = transaction.exchangeRate {
                    Text(exchangeRate.displaySummary)
                        .font(.caption2)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                        .lineLimit(1)
                        .accessibilityLabel(exchangeRate.summary)
                }

                if let shortfall = transaction.changeAdjustment?.shortfall {
                    ProtectedAmountText(
                        value: shortfall.minorUnits > 0
                            ? "Change short · \(shortfall.formatted)"
                            : "Change adjusted · \(shortfall.formatted)",
                        isRevealed: areBalancesRevealed
                    )
                        .font(.caption2)
                        .foregroundStyle(PocketLedgerTheme.warning)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            ProtectedAmountText(value: displayAmountText, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(displayAmountColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 11)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }

    private var rowSubtitle: String {
        let detail: String
        if transaction.loanID != nil {
            detail = "Loan activity"
        } else {
            detail = transaction.kind == .expense
                ? store.categoryPath(for: transaction.categoryID)
                : transaction.kind.displayName
        }
        if accountContext != nil {
            return [detail, transaction.date.formatted(.dateTime.month(.abbreviated).day().year())]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        return "\(detail) · \(transaction.date.formatted(date: .omitted, time: .shortened))"
    }

    private var displaySubtitle: String {
        subtitleOverride ?? rowSubtitle
    }

    private var iconName: String {
        if transaction.loanID != nil { return "banknote" }
        if transaction.categoryID != nil {
            return store.ledgerIndex.categorySystemImage(for: transaction.categoryID)
        }

        switch transaction.kind {
        case .expense:
            return "arrow.up.right"
        case .income:
            return "arrow.down.left"
        case .transfer:
            return "arrow.left.arrow.right"
        }
    }

    private var accentColor: Color {
        switch transaction.kind {
        case .expense:
            return PocketLedgerTheme.warning
        case .income:
            return PocketLedgerTheme.income
        case .transfer:
            return PocketLedgerTheme.positive
        }
    }

    private var amountText: String {
        if let accountContext {
            let outgoing = accountMovementTotal(transaction.outflows, for: accountContext)
            let incoming = accountMovementTotal(transaction.inflows, for: accountContext)
            return [
                outgoing > 0
                    ? "− " + Money(currency: accountContext.currency, minorUnits: outgoing).formatted
                    : nil,
                incoming > 0
                    ? "+ " + Money(currency: accountContext.currency, minorUnits: incoming).formatted
                    : nil
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        }
        return store.transactionSummary(transaction, reportingCurrency: reportingCurrency)
    }

    private var displayAmountColor: Color {
        if let amountColorOverride { return amountColorOverride }
        guard let accountContext else { return accentColor }

        let outgoing = accountMovementTotal(transaction.outflows, for: accountContext)
        let incoming = accountMovementTotal(transaction.inflows, for: accountContext)
        if outgoing > 0 && incoming == 0 { return PocketLedgerTheme.warning }
        if incoming > 0 && outgoing == 0 { return PocketLedgerTheme.income }
        return PocketLedgerTheme.positive
    }

    private func accountMovementTotal(
        _ movements: [MoneyMovement],
        for account: Account
    ) -> Int64 {
        movements.reduce(Int64.zero) { total, movement in
            guard movement.accountID == account.id,
                  let converted = financeConvertedMinorUnits(
                      movement.money,
                      to: account.currency,
                      using: transaction.exchangeRate
                  ) else {
                return total
            }
            return total + converted
        }
    }

    private var displayAmountText: String {
        amountOverride ?? amountText
    }

    private var canEditTransaction: Bool {
        allowsActions && transaction.loanID == nil
    }

    private var canSelectTransaction: Bool {
        transaction.loanID == nil
    }
}
