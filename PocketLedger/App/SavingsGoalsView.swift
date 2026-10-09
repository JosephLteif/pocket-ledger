import SwiftUI

@MainActor
struct SavingsGoalsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @State private var editingGoal: SavingsGoal?
    @State private var isPresentingEditor = false
    @State private var goalToDelete: SavingsGoal?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Track savings targets without changing account balances.")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                if store.data.savingsGoals.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "flag")
                            .font(.title2)
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                        Text("No savings goals yet").font(.headline)
                        Text("Choose a target and update your progress as you save.")
                            .font(.subheadline)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Create a goal", action: presentNewGoal)
                            .buttonStyle(.glassProminent)
                            .tint(PocketLedgerTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                    .padding(.horizontal, 20)
                    .pocketGroupedSurface(cornerRadius: 20)
                } else {
                    ForEach(store.data.savingsGoals) { goal in
                        goalCard(goal)
                    }
                }
            }
            .padding(16)
        }
        .pocketScreen()
        .navigationTitle("Savings goals")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: presentNewGoal) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add savings goal")
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { editingGoal = nil }) {
            SavingsGoalEditor(store: store, goal: editingGoal)
        }
        .confirmationDialog(
            "Delete savings goal?",
            isPresented: Binding(
                get: { goalToDelete != nil },
                set: { if !$0 { goalToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let goalToDelete { _ = store.deleteSavingsGoal(id: goalToDelete.id) }
                self.goalToDelete = nil
            }
            Button("Cancel", role: .cancel) { goalToDelete = nil }
        }
    }

    private func goalCard(_ goal: SavingsGoal) -> some View {
        let progress = min(max(Double(goal.currentAmount.minorUnits) / Double(goal.targetAmount.minorUnits), 0), 1)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.name)
                    .font(.headline)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(progress >= 1 ? PocketLedgerTheme.positive : PocketLedgerTheme.accent)
            }

            ProgressView(value: progress)
                .tint(progress >= 1 ? PocketLedgerTheme.positive : PocketLedgerTheme.accent)
                .accessibilityLabel("Savings goal progress for \(goal.name)")
                .accessibilityValue("\(Int(progress * 100)) percent")

            Text("\(goal.currentAmount.formatted) saved of \(goal.targetAmount.formatted)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(PocketLedgerTheme.textSecondary)

            HStack {
                if progress >= 1 {
                    Label("Goal reached", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.positive)
                } else if let targetDate = goal.targetDate {
                    Text("Target \(targetDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                Spacer()
                Button("Update") { editingGoal = goal; isPresentingEditor = true }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { goalToDelete = goal } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Delete \(goal.name)")
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(PocketLedgerTheme.divider, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }

    private func presentNewGoal() {
        editingGoal = nil
        isPresentingEditor = true
    }
}

@MainActor
private struct SavingsGoalEditor: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal?
    @State private var name: String
    @State private var currency: LedgerCurrency
    @State private var targetText: String
    @State private var currentText: String
    @State private var includesTargetDate: Bool
    @State private var targetDate: Date
    @State private var errorMessage: String?

    init(store: LedgerStore, goal: SavingsGoal?) {
        _store = ObservedObject(wrappedValue: store)
        self.goal = goal
        _name = State(initialValue: goal?.name ?? "")
        _currency = State(initialValue: goal?.targetAmount.currency ?? .usd)
        _targetText = State(initialValue: Self.inputText(for: goal?.targetAmount) ?? "")
        _currentText = State(initialValue: Self.inputText(for: goal?.currentAmount) ?? "0")
        _includesTargetDate = State(initialValue: goal?.targetDate != nil)
        _targetDate = State(initialValue: goal?.targetDate ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("Name", text: $name)
                    Picker("Currency", selection: $currency) {
                        ForEach(LedgerCurrency.allCases) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                    CurrencyInputField("Target amount", text: $targetText, currency: currency)
                    CurrencyInputField("Saved so far", text: $currentText, currency: currency)
                    Toggle("Set a target date", isOn: $includesTargetDate)
                    if includesTargetDate {
                        DatePicker("Target date", selection: $targetDate, displayedComponents: .date)
                    }
                    Text("Changing currency clears both amounts. Progress is tracked manually and does not change account balances.")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            .pocketListSurface()
            .navigationTitle(goal == nil ? "New savings goal" : "Edit savings goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .alert("Goal not saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: currency) { _, _ in
                targetText = ""
                currentText = "0"
            }
        }
    }

    private var parsedTarget: Money? {
        Money.parse(targetText, currency: currency)
    }

    private var parsedCurrent: Money? {
        currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Money(currency: currency, minorUnits: 0)
            : Money.parse(currentText, currency: currency)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (parsedTarget?.minorUnits ?? 0) > 0
            && (parsedCurrent?.minorUnits ?? -1) >= 0
    }

    private func save() {
        guard let targetAmount = parsedTarget, let currentAmount = parsedCurrent else {
            errorMessage = "Enter a valid target and saved amount."
            return
        }
        let saved = store.upsertSavingsGoal(
            SavingsGoal(
                id: goal?.id ?? UUID(),
                name: name,
                targetAmount: targetAmount,
                currentAmount: currentAmount,
                targetDate: includesTargetDate ? targetDate : nil
            )
        )
        if saved {
            dismiss()
        } else {
            errorMessage = store.lastActionStatus ?? "The goal could not be saved."
        }
    }

    private static func inputText(for amount: Money?) -> String? {
        guard let amount else { return nil }
        return NSDecimalNumber(
            decimal: Decimal(amount.minorUnits) / Decimal(amount.currency.minorUnitScale)
        ).stringValue
    }
}
