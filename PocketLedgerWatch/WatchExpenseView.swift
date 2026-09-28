import SwiftUI

struct WatchExpenseView: View {
    @ObservedObject var store: WatchLedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var note = ""
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var validationMessage: String?
    @State private var saveFeedbackTrigger = 0
    @State private var isShowingDiscardConfirmation = false
    private let commandToCorrect: WatchExpenseCommand?

    init(store: WatchLedgerStore, commandToCorrect: WatchExpenseCommand? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.commandToCorrect = commandToCorrect
        _amount = State(initialValue: commandToCorrect.map {
            $0.amount.currency.formattedInput(minorUnits: $0.amount.minorUnits)
        } ?? "")
        _note = State(initialValue: commandToCorrect?.note ?? "")
        _accountID = State(initialValue: commandToCorrect?.accountID)
        _categoryID = State(initialValue: commandToCorrect?.categoryID)
    }

    private var accounts: [WatchAccountSummary] {
        (store.snapshot?.accounts ?? []).filter(\.canUseForExpense)
    }

    private var categories: [WatchCategorySummary] {
        store.snapshot?.categories ?? []
    }

    private var categorySections: [CategorySection] {
        var groupedCategories: [String: [WatchCategorySummary]] = [:]
        for category in categories {
            let parentName = category.path.split(separator: "/", maxSplits: 1).first.map(String.init)
                ?? category.path
            groupedCategories[parentName, default: []].append(category)
        }

        var sections: [CategorySection] = []
        for (parentName, categories) in groupedCategories {
            let sortedCategories = categories.sorted { lhs, rhs in
                lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
            sections.append(CategorySection(
                parentName: parentName,
                categories: sortedCategories
            ))
        }

        return sections.sorted { lhs, rhs in
            lhs.parentName.localizedCaseInsensitiveCompare(rhs.parentName) == .orderedAscending
        }
    }

    private var selectedAccount: WatchAccountSummary? {
        accounts.first { $0.id == accountID }
    }

    private var parsedAmount: Money? {
        guard let currency = selectedAccount?.currency else { return nil }
        return Money.parse(amount, currency: currency)
    }

    var body: some View {
        Form {
            if let commandToCorrect,
               let failure = store.failedExpenseMessages[commandToCorrect.id] {
                Section("Needs attention") {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Retry without changes", systemImage: "arrow.clockwise") {
                        store.retryFailedExpense(id: commandToCorrect.id)
                        dismiss()
                    }
                }
            }

            if accounts.isEmpty {
                Text("No active account is available for an expense.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Amount", text: $amount)

                Picker("Account", selection: $accountID) {
                    Text("Choose account").tag(nil as UUID?)
                    ForEach(accounts) { account in
                        Text("\(account.name) (\(account.currency.rawValue))")
                            .tag(Optional(account.id))
                    }
                }

                Picker("Category", selection: $categoryID) {
                    Text("Uncategorized").tag(nil as UUID?)
                    ForEach(categorySections) { section in
                        Section {
                            ForEach(section.categories) { category in
                                Text(categoryLabel(category, parentName: section.parentName))
                                    .tag(Optional(category.id))
                            }
                        } header: {
                            Text(section.parentName)
                        }
                    }
                }

                TextField("Note", text: $note)

                Button(commandToCorrect == nil ? "Queue expense" : "Save corrections and retry") {
                    saveExpense()
                }
                .disabled((parsedAmount?.minorUnits ?? 0) <= 0 || accountID == nil)

                if let commandToCorrect {
                    Button("Discard failed expense", role: .destructive) {
                        isShowingDiscardConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(commandToCorrect == nil ? "Expense" : "Review expense")
        .sensoryFeedback(.success, trigger: saveFeedbackTrigger)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .onAppear {
            normalizeSelections()
        }
        .onChange(of: store.snapshot) { _, _ in normalizeSelections() }
        .alert(
            "Cannot save expense",
            isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(validationMessage ?? "Check the expense details and try again.")
        }
        .confirmationDialog(
            "Discard this failed expense?",
            isPresented: $isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard expense", role: .destructive) {
                if let commandToCorrect {
                    store.discardFailedExpense(id: commandToCorrect.id)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the rejected expense from the Watch queue.")
        }
    }

    private func categoryLabel(_ category: WatchCategorySummary, parentName: String) -> String {
        guard category.path != parentName else { return category.path }
        let childName = category.path.split(separator: "/").dropFirst().joined(separator: " / ")
        return "  \(childName)"
    }

    private func normalizeSelections() {
        let hasAvailableAccount = accountID.map { selectedID in
            accounts.contains(where: { $0.id == selectedID })
        } ?? false
        if !hasAvailableAccount {
            accountID = accounts.first?.id
        }

        if let categoryID,
           !categories.contains(where: { $0.id == categoryID }) {
            self.categoryID = nil
        }
    }

    private struct CategorySection: Identifiable {
        let parentName: String
        let categories: [WatchCategorySummary]

        var id: String { parentName }
    }

    private func saveExpense() {
        guard let accountID,
              let amount = parsedAmount,
              amount.minorUnits > 0 else {
            validationMessage = "Enter a positive amount and choose an account."
            return
        }

        if let commandToCorrect {
            store.correctAndRetryExpense(
                id: commandToCorrect.id,
                amount: amount,
                accountID: accountID,
                categoryID: categoryID,
                note: note
            )
        } else {
            store.queueExpense(
                amount: amount,
                accountID: accountID,
                categoryID: categoryID,
                note: note
            )
        }
        saveFeedbackTrigger += 1
        dismiss()
    }
}
