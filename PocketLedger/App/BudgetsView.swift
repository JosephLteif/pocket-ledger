import SwiftUI

@MainActor
struct BudgetsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @ObservedObject private var proAccess = ProEntitlementStore.shared
    let onAddAction: (AddAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @State private var editingBudget: LedgerBudget?
    @State private var isPresentingEditor = false
    @State private var budgetToDelete: LedgerBudget?
    @State private var budgetSummaries: [DashboardBudgetSnapshot] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                    Text("Keep monthly spending intentional")
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)

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
            .padding(16)
        }
        .pocketScreen()
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    if !proAccess.hasProAccess,
                       store.data.budgets.count >= PocketLedgerTierPolicy.freeBudgetLimit {
                        ProUpgradeButton(feature: .budgets) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Unlock more budgets with Pro")
                    } else {
                        Button(action: presentNewBudget) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add budget")
                    }
                    .accessibilityHint("Creates a new monthly budget")
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { editingBudget = nil }) {
            BudgetEditor(store: store, budget: editingBudget)
        }
        .onAppear(perform: refreshBudgetSummaries)
        .onChange(of: store.ledgerRevision) { _, _ in
            withAnimation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion)) {
                refreshBudgetSummaries()
            }
        }
        .confirmationDialog(deleteBudgetConfirmationTitle, isPresented: Binding(
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

    private func budgetCard(_ summary: DashboardBudgetSnapshot) -> some View {
        let budget = summary.budget
        let spent = summary.spent
        let allowance = summary.allowance
        let ratio = summary.ratio
        let over = summary.isOver
        let remaining = summary.remaining
        let projectedOver = summary.isProjectedOver

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.categoryPath).font(.headline)
                    Text("This month · \(budget.currency.rawValue)")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer()
                ProtectedAmountText(
                    value: "\(spent.formatted) / \(allowance.formatted)",
                    isRevealed: areBalancesRevealed
                )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.textPrimary)
            }
            ProgressView(value: ratio)
                .tint(projectedOver ? PocketLedgerTheme.warning : PocketLedgerTheme.accent)
                .animation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion), value: ratio)
            ProtectedAmountText(
                value: over
                    ? "Over by \(Money(currency: budget.currency, minorUnits: -remaining).formatted)"
                    : "Remaining \(Money(currency: budget.currency, minorUnits: remaining).formatted)",
                isRevealed: areBalancesRevealed
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(over ? PocketLedgerTheme.warning : PocketLedgerTheme.positive)
            HStack {
                Text("Scheduled through month-end")
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Spacer()
                ProtectedAmountText(
                    value: summary.scheduled.formatted,
                    isRevealed: areBalancesRevealed
                )
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
            .font(.caption.monospacedDigit())
            HStack {
                ProtectedAmountText(
                    value: "Projected \(summary.projected.formatted)",
                    isRevealed: areBalancesRevealed
                )
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
                        onAddAction: onAddAction,
                        security: security,
                        initialFilter: .expense,
                        initialPeriod: .thisMonth,
                        initialCategoryID: budget.categoryID,
                        initialCategoryIncludesDescendants: false,
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

    private func presentNewBudget() {
        editingBudget = nil
        isPresentingEditor = true
    }

    private var deleteBudgetConfirmationTitle: String {
        guard let budgetToDelete else { return "Delete budget?" }
        return "Delete budget for \(store.categoryPath(for: budgetToDelete.categoryID))?"
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
    @State private var categoryID: UUID?
    @State private var currency: LedgerCurrency
    @State private var amount: String
    @State private var rollover: Bool
    @State private var errorMessage: String?
    @State private var isSelectingCategory = false
    @State private var isConfirmingDiscard = false
    @State private var isShowingProUpgrade = false

    init(store: LedgerStore, budget: LedgerBudget?) {
        _store = ObservedObject(wrappedValue: store)
        self.budget = budget
        _categoryID = State(initialValue: budget?.categoryID ?? store.activeCategories.first?.id)
        _currency = State(initialValue: budget?.currency ?? .usd)
        _amount = State(initialValue: budget.map { NSDecimalNumber(decimal: Decimal($0.monthlyLimit.minorUnits) / Decimal($0.currency.minorUnitScale)).stringValue } ?? "")
        _rollover = State(initialValue: budget?.rollover ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Budget") {
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
                }
            }
            .pocketListSurface()
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
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
                    includeUncategorized: false
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
                || Money.parse(amount, currency: currency) != budget.monthlyLimit.recast(to: currency)
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
        let saved = store.upsertBudget(
            LedgerBudget(
                id: budget?.id ?? UUID(),
                categoryID: categoryID,
                currency: currency,
                monthlyLimit: limit,
                rollover: rollover,
                startedAt: budget?.startedAt ?? .now
            )
        )
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
