import SwiftUI

@MainActor
struct BudgetsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @ObservedObject private var proAccess = ProEntitlementStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingBudget: LedgerBudget?
    @State private var isPresentingEditor = false
    @State private var budgetToDelete: LedgerBudget?
    @State private var budgetSummaries: [DashboardBudgetSnapshot] = []
    @State private var isShowingProUpgrade = false
    @State private var selectedMonth: Date?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                monthPicker

                if let selectedMonth {
                    historicalBudgets(for: selectedMonth)
                } else {
                    Text(proAccess.hasProAccess
                         ? "\(store.data.budgets.count) budgets"
                         : "\(store.data.budgets.count) of \(PocketLedgerTierPolicy.freeBudgetLimit) budgets")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)

                    if !proAccess.hasProAccess,
                       store.data.budgets.count >= PocketLedgerTierPolicy.freeBudgetLimit {
                        ProUpgradePrompt(
                            title: "Need more budgets?",
                            detail: "Pro removes the budget limit and adds rollover planning.",
                            feature: .budgets
                        )
                    }

                    if budgetSummaries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "chart.bar.doc.horizontal")
                                .font(.title2)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                            Text("No budgets yet").font(.headline)
                            Text("Set a monthly limit for a category to track progress here.")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("Create budget", action: presentNewBudget)
                                .buttonStyle(.glassProminent)
                                .tint(PocketLedgerTheme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                        .padding(.horizontal, 20)
                        .pocketGroupedSurface(cornerRadius: 20)
                    } else {
                        ForEach(budgetSummaries) { summary in
                            budgetCard(summary)
                        }
                    }
                }
            }
            .padding(16)
        }
        .pocketScreen()
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    if selectedMonth != nil {
                        EmptyView()
                    } else if !proAccess.hasProAccess,
                       store.data.budgets.count >= PocketLedgerTierPolicy.freeBudgetLimit {
                        ProUpgradeButton(feature: .budgets) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Unlock more budgets with Pro")
                        .accessibilityHint("Creates a new monthly budget")
                    } else {
                        Button(action: presentNewBudget) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add budget")
                        .accessibilityHint("Creates a new monthly budget")
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { editingBudget = nil }) {
            BudgetEditor(store: store, budget: editingBudget, month: selectedMonth)
        }
        .background {
            Color.clear.sheet(isPresented: $isShowingProUpgrade) {
                ProUpgradeView(access: proAccess)
            }
        }
        .onAppear(perform: refreshBudgetSummaries)
        .onChange(of: store.ledgerRevision) { _, _ in
            withAnimation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion)) {
                refreshBudgetSummaries()
            }
        }
        .confirmationDialog("Delete budget?", isPresented: Binding(
            get: { budgetToDelete != nil },
            set: { if !$0 { budgetToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let budgetToDelete { _ = store.deleteBudget(id: budgetToDelete.id) }
                self.budgetToDelete = nil
            }
            Button("Cancel", role: .cancel) { budgetToDelete = nil }
        }
    }

    private var monthPicker: some View {
        let calendar = Calendar.current
        let now = Date.now
        let current = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let earliest = store.data.firstBudgetMonth(using: store.ledgerIndex, calendar: calendar, now: now)
        let month = selectedMonth ?? current

        return HStack {
            Button {
                selectedMonth = calendar.date(byAdding: .month, value: -1, to: month)
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous month")
            .disabled(month <= earliest)

            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Spacer()

            Button {
                let next = calendar.date(byAdding: .month, value: 1, to: month)
                selectedMonth = next.flatMap { $0 < current ? $0 : nil }
            } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next month")
            .disabled(selectedMonth == nil)
        }
        .buttonStyle(.borderless)
        .tint(PocketLedgerTheme.accent)
        .pocketGroupedSurface(cornerRadius: 20)
    }

    @ViewBuilder
    private func historicalBudgets(for month: Date) -> some View {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 0)
        let budgets = store.data.budgetMonths(for: interval, using: store.ledgerIndex, calendar: calendar)
        if budgets.isEmpty {
            ContentUnavailableView("No budgets for this month", systemImage: "chart.bar.doc.horizontal")
        } else {
            ForEach(budgets) { budget in
                VStack(alignment: .leading, spacing: 12) {
                    budgetProgress(
                        categoryPath: budget.categoryPath,
                        spent: budget.spent,
                        allowance: budget.allowance,
                        monthlyLimit: budget.monthlyLimit
                    )
                    if !store.data.budgetHistory.contains(where: { $0.id == budget.id }),
                       let activeBudget = store.data.budgets.first(where: { $0.id == budget.budgetID }) {
                        Button("Edit limit") {
                            editingBudget = activeBudget
                            isPresentingEditor = true
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit limit for \(budget.categoryPath)")
                    }
                }
                .padding(16)
                .pocketGroupedSurface(cornerRadius: 20)
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(PocketLedgerTheme.divider, lineWidth: 1) }
            }
        }
    }

    private func budgetCard(_ summary: DashboardBudgetSnapshot) -> some View {
        let budget = summary.budget
        let projectedOver = summary.isProjectedOver

        return VStack(alignment: .leading, spacing: 12) {
            budgetProgress(
                categoryPath: summary.categoryPath,
                spent: summary.spent,
                allowance: summary.allowance,
                monthlyLimit: budget.limit(for: .now),
                projectedOver: projectedOver
            )
            HStack {
                Text("Projected \(summary.projected.formatted)")
                    .font(.caption)
                    .foregroundStyle(projectedOver ? PocketLedgerTheme.warning : PocketLedgerTheme.textSecondary)
                Spacer()
                Text("\(summary.daysLeft) days left")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }
            HStack {
                NavigationLink {
                    TransactionsView(
                        store: store,
                        security: security,
                        initialFilter: .expense,
                        initialPeriod: .thisMonth,
                        initialCategoryID: budget.categoryID,
                        initialReportingCurrency: budget.currency
                    )
                } label: {
                    Label("View transactions", systemImage: "list.bullet")
                }
                .buttonStyle(.glass)
                .tint(PocketLedgerTheme.accent)
                Spacer()
                Button("Edit") { editingBudget = budget; isPresentingEditor = true }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { budgetToDelete = budget } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Delete budget")
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(PocketLedgerTheme.divider, lineWidth: 1) }
    }

    @ViewBuilder
    private func budgetProgress(
        categoryPath: String,
        spent: Money,
        allowance: Money,
        monthlyLimit: Money?,
        projectedOver: Bool = false
    ) -> some View {
        let remaining = allowance.minorUnits - spent.minorUnits
        let over = remaining < 0
        let ratio = min(max(Double(spent.minorUnits) / Double(max(allowance.minorUnits, 1)), 0), 1)
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(categoryPath).font(.headline)
                Text(allowance.currency.rawValue)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
            Spacer()
            Text("\(spent.formatted) / \(allowance.formatted)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.textPrimary)
        }
        ProgressView(value: ratio)
            .tint(over || projectedOver ? PocketLedgerTheme.warning : PocketLedgerTheme.accent)
            .animation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion), value: ratio)
        if let monthlyLimit, monthlyLimit != allowance {
            Text("Monthly limit \(monthlyLimit.formatted)")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        Text(over
             ? "Over by \(Money(currency: allowance.currency, minorUnits: -remaining).formatted)"
             : "Remaining \(Money(currency: allowance.currency, minorUnits: remaining).formatted)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.positive)
    }

    private func presentNewBudget() {
        guard PocketLedgerTierPolicy.canCreateBudget(
            count: store.data.budgets.count,
            hasPro: proAccess.hasProAccess
        ) else {
            proAccess.requestUpgrade(for: .budgets)
            isShowingProUpgrade = true
            return
        }
        editingBudget = nil
        isPresentingEditor = true
    }

    private func refreshBudgetSummaries() {
        budgetSummaries = DashboardSnapshot.makeBudgetSummaries(
            data: store.data,
            index: store.ledgerIndex
        )
    }
}

@MainActor
private struct BudgetEditor: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject private var proAccess = ProEntitlementStore.shared
    @Environment(\.dismiss) private var dismiss
    let budget: LedgerBudget?
    let month: Date?
    private let initialLimit: Money?
    @State private var categoryID: UUID?
    @State private var currency: LedgerCurrency
    @State private var amount: String
    @State private var rollover: Bool
    @State private var errorMessage: String?
    @State private var isSelectingCategory = false
    @State private var isConfirmingDiscard = false
    @State private var isShowingProUpgrade = false

    init(store: LedgerStore, budget: LedgerBudget?, month: Date?) {
        _store = ObservedObject(wrappedValue: store)
        self.budget = budget
        self.month = month
        let initialLimit = budget?.limit(for: month ?? .now)
        self.initialLimit = initialLimit
        _categoryID = State(initialValue: budget?.categoryID ?? store.activeCategories.first?.id)
        _currency = State(initialValue: budget?.currency ?? .usd)
        _amount = State(initialValue: initialLimit.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / Decimal($0.currency.minorUnitScale)).stringValue } ?? "")
        _rollover = State(initialValue: budget?.rollover ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let month {
                    Section {
                        LabeledContent("Category", value: selectedCategoryPath)
                        CurrencyInputField("Monthly limit", text: $amount, currency: currency)
                    } header: {
                        Text(month.formatted(.dateTime.month(.wide).year()))
                    } footer: {
                        Text("Following months use this limit until the next saved change.")
                    }
                } else {
                    Section {
                        Button {
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
                        CurrencyInputField("Monthly limit", text: $amount, currency: $currency)
                        if !canSave {
                            Label(
                                categoryID == nil ? "Choose a category to save this budget." : "Enter a positive monthly limit to save.",
                                systemImage: "info.circle"
                            )
                            .font(.footnote)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                        Toggle("Rollover unused amount", isOn: $rollover)
                            .disabled(!proAccess.hasProAccess && !rollover)
                        if !proAccess.hasProAccess && !rollover {
                            ProUpgradePrompt(
                                title: "Budget rollover",
                                detail: "Carry unused amounts forward with Pro.",
                                feature: .budgetRollover
                            )
                        }
                    } header: {
                        Text("Budget")
                    } footer: {
                        Text("Following months use this limit until the next saved change.")
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle(month != nil ? "Edit monthly limit" : budget == nil ? "New budget" : "Edit budget")
            .interactiveDismissDisabled(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .alert("Budget not saved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $isSelectingCategory) {
                CategorySelectionSheet(
                    categories: store.activeCategories,
                    selectedCategoryID: $categoryID,
                    includeUncategorized: false,
                    allowsParentSelection: true
                )
            }
            .confirmationDialog("Discard budget changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .background {
                Color.clear.sheet(isPresented: $isShowingProUpgrade) {
                    ProUpgradeView(access: proAccess)
                }
            }
        }
    }

    private var selectedCategoryPath: String {
        categoryID.map { store.categoryPath(for: $0) } ?? "Choose a category"
    }

    private var hasUnsavedChanges: Bool {
        if let budget {
            return categoryID != budget.categoryID
                || currency != budget.currency
                || Money.parse(amount, currency: currency) != initialLimit?.recast(to: currency)
                || rollover != budget.rollover
        }
        return categoryID != store.activeCategories.first?.id
            || currency != .usd
            || !amount.isEmpty
            || rollover
    }

    private func cancel() {
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private var canSave: Bool {
        categoryID != nil && (Money.parse(amount, currency: currency)?.minorUnits ?? 0) > 0
    }

    private func save() {
        guard let categoryID, let limit = Money.parse(amount, currency: currency), limit.minorUnits > 0 else {
            errorMessage = "Enter a positive monthly limit."
            return
        }
        let saved: Bool
        if let month, let budget {
            saved = store.updateBudgetLimit(id: budget.id, limit: limit, for: month)
        } else {
            saved = store.upsertBudget(
                LedgerBudget(
                    id: budget?.id ?? UUID(),
                    categoryID: categoryID,
                    currency: currency,
                    monthlyLimit: limit,
                    rollover: rollover,
                    startedAt: budget == nil ? .now : budget?.startedAt
                )
            )
        }
        if saved {
            dismiss()
        } else if let feature = store.proAccessRequired {
            proAccess.requestUpgrade(for: feature)
            isShowingProUpgrade = true
        } else {
            errorMessage = store.lastActionStatus ?? "The budget could not be saved."
        }
    }
}
