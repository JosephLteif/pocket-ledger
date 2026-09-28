import SwiftUI

@MainActor
struct SetupWizardView: View {
    static let completedKey = "pocketLedger.setupCompleted"

    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Self.completedKey) private var setupCompleted = false
    @State private var accountName = "Cash"
    @State private var accountType: AccountType = .cash
    @State private var currency: LedgerCurrency = .usd
    @State private var openingBalance = "0"
    @State private var addStarterCategories = true
    @State private var errorMessage: String?
    @State private var isShowingImport = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("A simple local ledger", systemImage: "wallet.pass.fill")
                        .font(.title3.weight(.bold))

                    Text("Start fresh with an account, or import an existing ledger below. You can also skip setup and finish later from More.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Start fresh") {
                    TextField("Account name", text: $accountName)
                    Picker("Type", selection: $accountType) {
                        ForEach(AccountType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                    CurrencyInputField("Opening balance", text: $openingBalance, currency: $currency)
                }

                Section("Import existing history") {
                    Button {
                        isShowingImport = true
                    } label: {
                        Label("Import existing history", systemImage: "square.and.arrow.down")
                    }
                    Text("Review an export from another finance app before adding it to Pocket Ledger.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Categories") {
                    Toggle("Add starter categories", isOn: $addStarterCategories)
                    Text("Food, Bills, Transport, and Shopping will be created as top-level categories.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Skip for now") {
                        complete()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle("Welcome to Pocket Ledger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create ledger", action: createLedger)
                }
            }
            .sheet(isPresented: $isShowingImport, onDismiss: finishSetupAfterImport) {
                NavigationStack {
                    DataTransferView(store: store, isImportOnly: true)
                }
            }
            .alert("Setup could not be completed", isPresented: errorPresented) {
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

    private func createLedger() {
        let trimmedName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a name for your first account."
            return
        }
        guard let balance = Money.parse(openingBalance, currency: currency) else {
            errorMessage = "Enter a valid opening balance."
            return
        }

        guard store.addAccount(
            Account(
                name: trimmedName,
                type: accountType,
                currency: currency,
                openingBalance: balance
            )
        ) else {
            errorMessage = store.lastActionStatus ?? "The account could not be saved."
            return
        }

        if addStarterCategories {
            for name in ["Food", "Bills", "Transport", "Shopping"] {
                _ = store.addCategory(LedgerCategory(name: name))
            }
        }
        complete()
    }

    private func complete() {
        setupCompleted = true
        dismiss()
    }

    private func finishSetupAfterImport() {
        guard !store.data.accounts.isEmpty
            || !store.data.categories.isEmpty
            || !store.data.transactions.isEmpty else { return }
        complete()
    }
}
