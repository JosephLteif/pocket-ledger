import Foundation
import SwiftUI

private enum LoanListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case lent = "Lent"
    case borrowed = "Borrowed"
    case dueSoon = "Due soon"
    case overdue = "Overdue"
    case settled = "Settled"

    var id: String { rawValue }
}

private func loanStatus(for loan: Loan) -> String {
    if loan.resolvedAt != nil { return "Resolved" }
    guard !loan.isSettled, let dueDate = loan.dueDate else {
        return loan.isSettled ? "Settled" : "Active"
    }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    if dueDate < today { return "Overdue" }
    if let soonLimit = calendar.date(byAdding: .day, value: 7, to: today), dueDate < soonLimit {
        return "Due soon"
    }
    return loan.payments.isEmpty ? "Active" : "Partially settled"
}

private extension LoanListFilter {
    func includes(_ loan: Loan) -> Bool {
        switch self {
        case .all: true
        case .lent: loan.direction == .lent && !loan.isSettled
        case .borrowed: loan.direction == .borrowed && !loan.isSettled
        case .dueSoon: loanStatus(for: loan) == "Due soon"
        case .overdue: loanStatus(for: loan) == "Overdue"
        case .settled: loan.isSettled
        }
    }
}

private func loanCounterpartyNames(in data: FinanceData) -> [String] {
    let names = (data.loanContacts.map(\.name) + data.loans.map(\.counterparty))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    return Array(Set(names))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

private func pastLoanCounterpartyNames(in data: FinanceData) -> [String] {
    let savedNames = data.loanContacts.map(\.name)
    let names = data.loans.map { $0.counterparty.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { historicalName in
            !historicalName.isEmpty && !savedNames.contains { savedName in
                savedName.localizedCaseInsensitiveCompare(historicalName) == .orderedSame
            }
        }

    return Array(Set(names))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

private func loanContactID(for counterparty: String, in data: FinanceData) -> UUID? {
    data.loanContacts.first {
        $0.name.localizedCaseInsensitiveCompare(counterparty) == .orderedSame
    }?.id
}

private struct LoanPersonGroup: Identifiable {
    let id: String
    let name: String
    let loans: [Loan]

    var activeLoans: [Loan] { loans.filter { !$0.isSettled } }
    var settledLoans: [Loan] { loans.filter(\.isSettled) }
    var activeCurrencies: [LedgerCurrency] {
        LedgerCurrency.allCases.filter { currency in activeLoans.contains { $0.currency == currency } }
    }

    func netBalance(in currency: LedgerCurrency) -> Int64 {
        activeLoans.reduce(Int64.zero) { total, loan in
            guard loan.currency == currency else { return total }
            let sign: Int64 = loan.direction == .lent ? 1 : -1
            return total + loan.outstandingAmount.minorUnits * sign
        }
    }
}

private func loanPersonGroups(in data: FinanceData) -> [LoanPersonGroup] {
    Dictionary(grouping: data.loans) { loanCounterpartyKey(for: $0, in: data) }
        .compactMap { entry in
            guard let firstLoan = entry.value.first else { return nil }
            return LoanPersonGroup(
                id: entry.key,
                name: firstLoan.counterparty,
                loans: entry.value
            )
        }
        .sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
}

@MainActor
struct LoansView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @State private var filter: LoanListFilter = .all
    @State private var isPresentingLoanEditor = false
    @State private var notificationMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    var body: some View {
        List {
            overviewSection

            Section("People") {
                NavigationLink {
                    LoanPeopleView(store: store)
                } label: {
                    HStack {
                        Label("Manage people", systemImage: "person.2")
                        Spacer()
                        Text("\(store.data.loanContacts.count)")
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
            }

            if !store.legacyLoanAccountsNeedingSetup.isEmpty {
                Section("Set up existing loan accounts") {
                    ForEach(store.legacyLoanAccountsNeedingSetup) { account in
                        NavigationLink {
                            LegacyLoanConversionView(store: store, account: account)
                                .modifier(FinancialAmountEditorCover(security: security))
                        } label: {
                            HStack(spacing: 12) {
                                PocketIcon(
                                    systemImage: "arrow.triangle.2.circlepath",
                                    tint: PocketLedgerTheme.warning,
                                    size: 36
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Review current balance and convert to a managed loan")
                                        .font(.caption)
                                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                                }
                                Spacer(minLength: 8)
                                ProtectedAmountText(
                                    value: store.balance(for: account).formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.caption.weight(.semibold).monospacedDigit())
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LoanListFilter.allCases) { item in
                            Button {
                                filter = item
                            } label: {
                                Text(item.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(filter == item ? .white : PocketLedgerTheme.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        filter == item ? PocketLedgerTheme.accent : PocketLedgerTheme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                if filteredPersonGroups.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "arrow.left.arrow.right.circle",
                        description: Text(emptyDescription)
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredPersonGroups) { person in
                        NavigationLink {
                            LoanPersonDetailView(
                                store: store,
                                security: security,
                                personID: person.id,
                                filter: filter
                            )
                        } label: {
                            LoanPersonRow(
                                person: person,
                                areBalancesRevealed: areBalancesRevealed
                            )
                        }
                        .listRowBackground(PocketLedgerTheme.surface)
                    }
                }
            } header: {
                Text("By person")
            }

            if activeLoans.contains(where: { $0.dueDate != nil }) {
                Section {
                    Button {
                        Task {
                            notificationMessage = await NotificationService.requestLoanNotifications(
                                loans: store.data.loans
                            )
                        }
                    } label: {
                        Label("Enable loan reminders", systemImage: "bell.badge")
                    }
                } footer: {
                    Text("Reminders use your saved timing preference. Due dates stay visible here if notifications are unavailable.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .pocketScreen()
        .navigationTitle("Loans")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingLoanEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add loan")
                }
            }
        }
        .sheet(isPresented: $isPresentingLoanEditor) {
            LoanEditor(store: store)
        }
        .alert("Loan reminders", isPresented: notificationMessagePresented) {
            Button("OK") { notificationMessage = nil }
        } message: {
            Text(notificationMessage ?? "")
        }
    }

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LedgerCurrency.allCases) { currency in
                    let lent = store.assetBalance(for: currency).minorUnits
                        - store.availableBalance(for: currency).minorUnits
                    let borrowed = store.liabilityBalance(for: currency).minorUnits
                        - store.loanBalance(for: currency).minorUnits
                    if lent != 0 || borrowed != 0 {
                        HStack(spacing: 10) {
                            Text(currency.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("Lent")
                                    .font(.caption2)
                                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                                ProtectedAmountText(
                                    value: Money(currency: currency, minorUnits: lent).formatted,
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
                                    value: Money(currency: currency, minorUnits: borrowed).formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(PocketLedgerTheme.warning)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    loanCountBadge(title: "Due soon", count: dueSoonLoans.count, tint: PocketLedgerTheme.accent)
                    loanCountBadge(title: "Overdue", count: overdueLoans.count, tint: PocketLedgerTheme.warning)
                    loanCountBadge(title: "Settled", count: settledLoans.count, tint: PocketLedgerTheme.textSecondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Loan overview")
        }
    }

    private func loanCountBadge(title: String, count: Int, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.headline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(PocketLedgerTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private var activeLoans: [Loan] { store.data.loans.filter { !$0.isSettled } }
    private var settledLoans: [Loan] { store.data.loans.filter(\.isSettled) }
    private var overdueLoans: [Loan] { activeLoans.filter { loanStatus(for: $0) == "Overdue" } }
    private var dueSoonLoans: [Loan] { activeLoans.filter { loanStatus(for: $0) == "Due soon" } }

    private var filteredPersonGroups: [LoanPersonGroup] {
        loanPersonGroups(in: store.data).filter { person in
            person.loans.contains { filter.includes($0) }
        }
    }

    private var emptyTitle: String {
        filter == .all ? "No loans yet" : "No \(filter.rawValue.lowercased()) loans"
    }

    private var emptyDescription: String {
        filter == .all
            ? "Add a loan you gave or received to track its balance and due date."
            : "Loans matching this view will appear here."
    }

    private var notificationMessagePresented: Binding<Bool> {
        Binding(get: { notificationMessage != nil }, set: { if !$0 { notificationMessage = nil } })
    }
}

@MainActor
private struct LoanRow: View {
    let loan: Loan
    let status: String
    let areBalancesRevealed: Bool

    var body: some View {
        HStack(spacing: 12) {
            PocketIcon(
                systemImage: loan.direction == .lent ? "arrow.up.right" : "arrow.down.left",
                tint: loan.isSettled ? PocketLedgerTheme.textTertiary : PocketLedgerTheme.accent,
                size: 36
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(loan.direction.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status == "Overdue" ? PocketLedgerTheme.warning : PocketLedgerTheme.textSecondary)
                if let description = loan.description,
                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .lineLimit(2)
                }
                if loan.resolvedAt == nil, !loan.payments.isEmpty {
                    let settledMinorUnits = loan.payments.reduce(Int64.zero) { $0 + $1.amount.minorUnits }
                    ProtectedAmountText(
                        value: "Settled \(Money(currency: loan.currency, minorUnits: settledMinorUnits).formatted) of \(loan.startingAmount.formatted)",
                        isRevealed: areBalancesRevealed
                    )
                        .font(.caption2)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                Text("Started \(loan.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                if let dueDate = loan.dueDate, !loan.isSettled {
                    Text("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            ProtectedAmountText(value: loan.outstandingAmount.formatted, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(loan.isSettled ? PocketLedgerTheme.textSecondary : PocketLedgerTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct LoanPersonRow: View {
    let person: LoanPersonGroup
    let areBalancesRevealed: Bool

    var body: some View {
        HStack(spacing: 12) {
            PocketIcon(systemImage: "person.crop.circle", tint: PocketLedgerTheme.accent, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(person.name)
                    .font(.subheadline.weight(.semibold))
                Text(loanCountDescription)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                ForEach(person.activeCurrencies) { currency in
                    let balance = person.netBalance(in: currency)
                    HStack(spacing: 5) {
                        Text("\(currency.rawValue) · \(balanceLabel(for: balance))")
                        Spacer(minLength: 4)
                        ProtectedAmountText(
                            value: Money(currency: currency, minorUnits: abs(balance)).formatted,
                            isRevealed: areBalancesRevealed
                        )
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .font(.caption)
                    .foregroundStyle(balanceColor(for: balance))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func balanceLabel(for amount: Int64) -> String {
        if amount > 0 { return "Net owed to you" }
        if amount < 0 { return "Net you owe" }
        return "No net balance"
    }

    private func balanceColor(for amount: Int64) -> Color {
        if amount > 0 { return PocketLedgerTheme.income }
        if amount < 0 { return PocketLedgerTheme.warning }
        return PocketLedgerTheme.textSecondary
    }

    private var loanCountDescription: String {
        let open = person.activeLoans.count
        let settled = person.settledLoans.count
        if open == 0 { return "\(settled) settled loan\(settled == 1 ? "" : "s")" }
        if settled == 0 { return "\(open) open loan\(open == 1 ? "" : "s")" }
        return "\(open) open · \(settled) settled"
    }
}

@MainActor
private struct LoanPersonBalanceRow: View {
    let personName: String
    let currency: LedgerCurrency
    let netAmount: Int64
    let openLoanCount: Int
    let areBalancesRevealed: Bool
    let onSettle: () -> Void
    let onResolveWithoutPayment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(balanceDescription)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                    Text("\(currency.rawValue) · \(openLoanCount) open loan\(openLoanCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer(minLength: 8)
                ProtectedAmountText(
                    value: Money(currency: currency, minorUnits: abs(netAmount)).formatted,
                    isRevealed: areBalancesRevealed
                )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(spacing: 8) {
                Button(action: onSettle) {
                    Label(actionTitle, systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(actionTitle) in \(currency.rawValue)")
                if netAmount != 0 {
                    Menu {
                        Button("Resolve all without payment", systemImage: "checkmark.circle", role: .destructive, action: onResolveWithoutPayment)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More settlement options for \(currency.rawValue)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var balanceDescription: String {
        if netAmount > 0 { return "\(personName) owes you" }
        if netAmount < 0 { return "You owe \(personName)" }
        return "Balanced with \(personName)"
    }

    private var actionTitle: String {
        netAmount == 0 ? "Close balanced loans" : "Settle with accounts"
    }
}

@MainActor
private struct LoanPersonDetailView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    let personID: String
    let filter: LoanListFilter
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @State private var currencyToResolve: LedgerCurrency?
    @State private var currencyToSettle: LedgerCurrency?
    @State private var errorMessage: String?

    private var person: LoanPersonGroup? {
        loanPersonGroups(in: store.data).first { $0.id == personID }
    }

    var body: some View {
        List {
            if let person {
                Section {
                    if person.activeLoans.isEmpty {
                        Text("No outstanding balance.")
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    } else {
                        ForEach(person.activeCurrencies) { currency in
                            LoanPersonBalanceRow(
                                personName: person.name,
                                currency: currency,
                                netAmount: person.netBalance(in: currency),
                                openLoanCount: person.activeLoans.filter { $0.currency == currency }.count,
                                areBalancesRevealed: areBalancesRevealed,
                                onSettle: {
                                    if person.netBalance(in: currency) == 0 {
                                        currencyToResolve = currency
                                    } else {
                                        currencyToSettle = currency
                                    }
                                },
                                onResolveWithoutPayment: { currencyToResolve = currency }
                            )
                        }
                    }
                } header: {
                    Text("Net balance")
                } footer: {
                    Text("Settle a nonzero balance across cash or bank accounts. Reciprocal loans are offset first; any remaining amount is applied to the oldest loans. You can also resolve all loans without recording a payment.")
                }

                Section("Loans") {
                    ForEach(person.loans.filter { filter.includes($0) }) { loan in
                        NavigationLink {
                            LoanDetailView(store: store, loanID: loan.id)
                        } label: {
                            LoanRow(
                                loan: loan,
                                status: loanStatus(for: loan),
                                areBalancesRevealed: areBalancesRevealed
                            )
                        }
                        .accessibilityIdentifier("loan-person-loan-\(loan.id)")
                        .listRowBackground(PocketLedgerTheme.surface)
                    }
                }
            } else {
                ContentUnavailableView("Person unavailable", systemImage: "person.crop.circle")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .pocketScreen()
        .navigationTitle(person?.name ?? "Loans")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { BalanceVisibilityToolbarItem(security: security) }
        .confirmationDialog(
            "Settle balance with \(person?.name ?? "this person")?",
            isPresented: resolveConfirmationPresented,
            titleVisibility: .visible
        ) {
            if currencyToResolve != nil {
                Button("Mark loans settled") { resolveSelectedCurrency() }
            }
            Button("Cancel", role: .cancel) { currencyToResolve = nil }
        } message: {
            Text(resolveMessage)
        }
        .alert("Could not settle loans", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $currencyToSettle) { currency in
            LoanPersonSettlementEditor(store: store, personID: personID, currency: currency)
                .modifier(FinancialAmountEditorCover(security: security))
        }
    }

    private var resolveMessage: String {
        guard let person, let currencyToResolve else { return "No account transaction will be created." }
        let net = person.netBalance(in: currencyToResolve)
        let amount = Money(currency: currencyToResolve, minorUnits: abs(net)).formatted
        let outcome = "This marks all open \(currencyToResolve.rawValue) loans with \(person.name) resolved without changing account balances or creating a transaction."
        guard areBalancesRevealed else { return outcome }
        let balance = net > 0
            ? "\(person.name) owes you \(amount)."
            : net < 0 ? "You owe \(person.name) \(amount)." : "There is no net amount to pay."
        return "\(balance) \(outcome)"
    }

    private var resolveConfirmationPresented: Binding<Bool> {
        Binding(get: { currencyToResolve != nil }, set: { if !$0 { currencyToResolve = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func resolveSelectedCurrency() {
        guard let person, let currencyToResolve else { return }
        let ids = person.activeLoans.filter { $0.currency == currencyToResolve }.map(\.id)
        self.currencyToResolve = nil
        guard store.resolveLoans(ids: ids) else {
            errorMessage = store.lastActionStatus ?? "The loan balance could not be resolved."
            return
        }
    }
}

private struct LoanSettlementSplitDraft: Identifiable {
    let id = UUID()
    var accountID: UUID?
    var amountText: String
}

@MainActor
private struct LoanPersonSettlementEditor: View {
    @ObservedObject var store: LedgerStore
    let personID: String
    let currency: LedgerCurrency
    @Environment(\.dismiss) private var dismiss
    @State private var accountSplits: [LoanSettlementSplitDraft]
    @State private var settlementDate = Date.now
    @State private var errorMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(store: LedgerStore, personID: String, currency: LedgerCurrency) {
        _store = ObservedObject(wrappedValue: store)
        self.personID = personID
        self.currency = currency
        let person = loanPersonGroups(in: store.data).first { $0.id == personID }
        let netBalance = person?.netBalance(in: currency) ?? 0
        let accountID = store.activeAccounts.first {
            !$0.isArchived && ($0.type == .cash || $0.type == .bankAccount) && $0.currency == currency
        }?.id
        _accountSplits = State(initialValue: [LoanSettlementSplitDraft(
            accountID: accountID,
            amountText: currency.formattedInput(minorUnits: abs(netBalance))
        )])
    }

    private var person: LoanPersonGroup? {
        loanPersonGroups(in: store.data).first { $0.id == personID }
    }

    private var netBalance: Int64 { person?.netBalance(in: currency) ?? 0 }

    private var earliestSettlementDate: Date {
        let firstStart = person?.activeLoans.filter { $0.currency == currency }.map(\.startedAt).min() ?? .now
        return min(Calendar.current.startOfDay(for: firstStart), .now)
    }

    private var eligibleAccounts: [Account] {
        store.activeAccounts.filter {
            !$0.isArchived && $0.currency == currency && ($0.type == .cash || $0.type == .bankAccount)
        }
    }

    private var parsedSplits: [MoneyMovement] {
        accountSplits.compactMap { split in
            guard let accountID = split.accountID,
                  let amount = Money.parse(split.amountText, currency: currency),
                  amount.minorUnits > 0 else { return nil }
            return MoneyMovement(accountID: accountID, money: amount)
        }
    }

    private var allocatedAmount: Int64 {
        parsedSplits.reduce(Int64.zero) { $0 + $1.money.minorUnits }
    }

    private var canSave: Bool {
        netBalance != 0
            && !accountSplits.isEmpty
            && parsedSplits.count == accountSplits.count
            && parsedSplits.allSatisfy { split in
                eligibleAccounts.contains { $0.id == split.accountID }
            }
            && allocatedAmount > 0
            && allocatedAmount <= abs(netBalance)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Net balance") {
                    LabeledContent(netBalance > 0 ? "Collect from \(person?.name ?? "person")" : "Pay \(person?.name ?? "person")") {
                        ProtectedAmountText(
                            value: Money(currency: currency, minorUnits: abs(netBalance)).formatted,
                            isRevealed: areBalancesRevealed
                        )
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    Text("Split all or part of this amount across accounts in \(currency.rawValue).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Settlement date") {
                    DatePicker("Date", selection: $settlementDate, in: earliestSettlementDate...Date.now, displayedComponents: .date)
                }

                Section("Account splits") {
                    if eligibleAccounts.isEmpty {
                        Text("Add a cash or bank account in \(currency.rawValue) to record this settlement.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($accountSplits) { $split in
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Account", selection: $split.accountID) {
                                    Text("Choose account").tag(Optional<UUID>.none)
                                    ForEach(eligibleAccounts) { account in
                                        Text(account.name).tag(Optional(account.id))
                                    }
                                }
                                CurrencyInputField("Amount", text: $split.amountText, currency: currency)
                                if accountSplits.count > 1 {
                                    Button("Remove split", role: .destructive) {
                                        accountSplits.removeAll { $0.id == split.id }
                                    }
                                }
                            }
                        }
                        Button("Add another account") {
                            accountSplits.append(LoanSettlementSplitDraft(accountID: nil, amountText: ""))
                        }
                        Text("Use cash or bank accounts in \(currency.rawValue).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Settlement preview") {
                    LabeledContent("Applied across accounts") {
                        ProtectedAmountText(
                            value: Money(currency: currency, minorUnits: allocatedAmount).formatted,
                            isRevealed: areBalancesRevealed
                        )
                    }
                    LabeledContent("Net balance remaining") {
                        ProtectedAmountText(
                            value: Money(currency: currency, minorUnits: max(0, abs(netBalance) - allocatedAmount)).formatted,
                            isRevealed: areBalancesRevealed
                        )
                    }
                    if allocatedAmount > abs(netBalance) {
                        Text("The split total cannot be greater than the net balance.")
                            .font(.footnote)
                            .foregroundStyle(PocketLedgerTheme.warning)
                    }
                    Text("Reciprocal loans are offset first. The account payments then reduce the oldest remaining loans first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle("Settle with \(person?.name ?? "person")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: save)
                        .disabled(!canSave)
                }
            }
            .alert("Settlement not saved", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var actionTitle: String {
        allocatedAmount == abs(netBalance) ? "Settle all" : "Record partial"
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        guard let person else {
            errorMessage = "This person is no longer available."
            return
        }
        let loanIDs = person.activeLoans.filter { $0.currency == currency }.map(\.id)
        guard store.settleLoansWithPerson(loanIDs: loanIDs, accountSplits: parsedSplits, date: settlementDate) else {
            errorMessage = store.lastActionStatus ?? "The person settlement could not be saved."
            return
        }
        dismiss()
    }
}

@MainActor
private struct LegacyLoanConversionView: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [LegacyLoanDraft]
    @State private var errorMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(store: LedgerStore, account: Account) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account
        let current = store.balance(for: account)
        let savedCounterparty = loanCounterpartyNames(in: store.data).first {
            $0.localizedCaseInsensitiveCompare(account.name) == .orderedSame
        }
        _drafts = State(initialValue: [LegacyLoanDraft(
            counterparty: account.name,
            amountText: account.currency.formattedInput(minorUnits: max(0, current.minorUnits)),
            selectedCounterparty: savedCounterparty
        )])
    }

    var body: some View {
        Form {
            Section("Current account") {
                LabeledContent("Account", value: account.name)
                LabeledContent("Currency", value: account.currency.rawValue)
                LabeledContent("Current balance") {
                    ProtectedAmountText(
                        value: currentBalance.formatted,
                        isRevealed: areBalancesRevealed
                    )
                }
                Text("Convert this account balance into managed loans and keep its existing transactions as history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if currentBalance.minorUnits == 0 {
                    Text("This loan account has no outstanding balance. Converting it archives the account and keeps its transaction history available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if currentBalance.minorUnits < 0 {
                    Text("This account has a negative balance. Reconcile it before converting it to a managed loan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Direction", selection: $draft.direction) {
                                ForEach(LoanDirection.allCases) { direction in
                                    Text(direction.displayName).tag(direction)
                                }
                            }
                            if counterpartyNames.isEmpty {
                                TextField(draft.direction.counterpartyLabel, text: $draft.counterparty)
                            } else {
                                Picker(draft.direction.counterpartyLabel, selection: $draft.selectedCounterparty) {
                                    Text("New counterparty").tag(Optional<String>.none)
                                    if !store.data.loanContacts.isEmpty {
                                        Section("Saved people") {
                                            ForEach(store.data.loanContacts) { contact in
                                                Text(contact.name).tag(Optional(contact.name))
                                            }
                                        }
                                    }
                                    if !pastLoanCounterpartyNames(in: store.data).isEmpty {
                                        Section("Past loan names") {
                                            ForEach(pastLoanCounterpartyNames(in: store.data), id: \.self) { name in
                                                Text(name).tag(Optional(name))
                                            }
                                        }
                                    }
                                }
                                if draft.selectedCounterparty == nil {
                                    TextField(draft.direction.counterpartyLabel, text: $draft.counterparty)
                                }
                            }
                            CurrencyInputField("Amount", text: $draft.amountText, currency: account.currency)
                            TextField("Description (optional)", text: $draft.descriptionText, axis: .vertical)
                                .lineLimit(2...4)
                            Toggle("Add due date", isOn: $draft.hasDueDate)
                            if draft.hasDueDate {
                                DatePicker("Due date", selection: $draft.dueDate, displayedComponents: .date)
                            }
                            if drafts.count > 1 {
                                Button("Remove loan", systemImage: "minus.circle", role: .destructive) {
                                    drafts.removeAll { $0.id == draft.id }
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Split into another loan", systemImage: "plus.circle") {
                        drafts.append(LegacyLoanDraft(
                            counterparty: account.name,
                            amountText: "",
                            direction: .borrowed,
                            hasDueDate: false,
                            dueDate: .now
                        ))
                    }
                }
            } header: {
                Text("Review loans")
            } footer: {
                Text("Each loan defaults to borrowed. Choose a direction for each one; the amounts must add up to the account’s current balance.")
            }

            Section {
                LabeledContent("Loan total") {
                    ProtectedAmountText(value: draftTotal.formatted, isRevealed: areBalancesRevealed)
                }
                LabeledContent("Difference") {
                    ProtectedAmountText(
                        value: Money(currency: account.currency, minorUnits: currentBalance.minorUnits - draftTotal.minorUnits).formatted,
                        isRevealed: areBalancesRevealed
                    )
                }
            }
        }
        .pocketListSurface()
        .navigationTitle("Convert loan account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Convert", action: convert)
                    .disabled(!canConvert)
            }
        }
        .alert("Loan account not converted", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var counterpartyNames: [String] {
        loanCounterpartyNames(in: store.data)
    }

    private var currentBalance: Money { store.balance(for: account) }

    private var parsedAmounts: [Money]? {
        let amounts = drafts.compactMap { Money.parse($0.amountText, currency: account.currency) }
        return amounts.count == drafts.count ? amounts : nil
    }

    private var draftTotal: Money {
        Money(currency: account.currency, minorUnits: parsedAmounts?.reduce(Int64.zero) { $0 + $1.minorUnits } ?? 0)
    }

    private var canConvert: Bool {
        if currentBalance.minorUnits == 0 { return true }
        guard currentBalance.minorUnits > 0,
              let amounts = parsedAmounts,
              amounts.allSatisfy({ $0.minorUnits > 0 }) else { return false }
        return amounts.reduce(Int64.zero) { $0 + $1.minorUnits } == currentBalance.minorUnits
            && drafts.allSatisfy {
                !($0.selectedCounterparty ?? $0.counterparty)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func convert() {
        let loans = currentBalance.minorUnits == 0 ? [] : drafts.compactMap { draft -> Loan? in
            guard let amount = Money.parse(draft.amountText, currency: account.currency) else { return nil }
            let counterparty = (draft.selectedCounterparty ?? draft.counterparty)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = draft.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            return Loan(
                counterparty: counterparty,
                counterpartyContactID: loanContactID(for: counterparty, in: store.data),
                description: description.isEmpty ? nil : description,
                direction: draft.direction,
                currency: account.currency,
                startingAmount: amount,
                startedAt: .now,
                dueDate: draft.hasDueDate ? draft.dueDate : nil,
                legacyAccountID: account.id
            )
        }
        guard store.convertLegacyLoanAccount(accountID: account.id, into: loans) else {
            errorMessage = store.lastActionStatus ?? "Check that the loan amounts match the account balance."
            return
        }
        dismiss()
    }
}

private struct LegacyLoanDraft: Identifiable {
    let id = UUID()
    var counterparty: String
    var amountText: String
    var descriptionText: String = ""
    var selectedCounterparty: String? = nil
    var direction: LoanDirection = .borrowed
    var hasDueDate: Bool = false
    var dueDate: Date = .now
}

@MainActor
struct LoanEditor: View {
    @ObservedObject var store: LedgerStore
    let loan: Loan?
    let onSave: (() -> Void)?
    private let wrapsInNavigationStack: Bool
    private let initialStartDate: Date
    private let initialAccountID: UUID?
    private let initialCurrency: LedgerCurrency
    @Environment(\.dismiss) private var dismiss
    @State private var counterparty: String
    @State private var selectedCounterparty: String?
    @State private var direction: LoanDirection
    @State private var amountText: String
    @State private var fundingMethod: LoanFundingMethod
    @State private var descriptionText: String
    @State private var loanCurrency: LedgerCurrency
    @State private var startedAt: Date
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var selectedAccountID: UUID?
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false

    init(
        store: LedgerStore,
        loan: Loan? = nil,
        onSave: (() -> Void)? = nil,
        wrapsInNavigationStack: Bool = true
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.loan = loan
        self.onSave = onSave
        self.wrapsInNavigationStack = wrapsInNavigationStack
        _counterparty = State(initialValue: loan?.counterparty ?? "")
        let savedCounterparty = loan.flatMap { loan in
            loanCounterpartyNames(in: store.data).first {
                $0.localizedCaseInsensitiveCompare(loan.counterparty) == .orderedSame
            }
        }
        _selectedCounterparty = State(initialValue: savedCounterparty)
        _direction = State(initialValue: loan?.direction ?? .borrowed)
        _amountText = State(initialValue: "")
        _fundingMethod = State(initialValue: .cashMovement)
        _descriptionText = State(initialValue: loan?.description ?? "")
        let startDate = loan?.startedAt ?? .now
        initialStartDate = startDate
        _startedAt = State(initialValue: startDate)
        _hasDueDate = State(initialValue: loan?.dueDate != nil)
        _dueDate = State(initialValue: loan?.dueDate ?? .now)
        let firstAccount = store.activeAccounts.first { $0.type == .cash || $0.type == .bankAccount }
        let accountID = loan?.settlementAccountID ?? firstAccount?.id
        initialAccountID = accountID
        _selectedAccountID = State(initialValue: accountID)
        let currency = loan?.currency ?? firstAccount?.currency ?? .usd
        initialCurrency = currency
        _loanCurrency = State(initialValue: currency)
    }

    @ViewBuilder
    var body: some View {
        if wrapsInNavigationStack {
            NavigationStack {
                editorForm
            }
        } else {
            editorForm
        }
    }

    private var editorForm: some View {
            Form {
                Section("Loan") {
                    if loan == nil {
                        Picker("Direction", selection: $direction) {
                            ForEach(LoanDirection.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                    }
                    if counterpartyNames.isEmpty {
                        TextField(counterpartyLabel, text: $counterparty)
                    } else {
                        Picker(counterpartyLabel, selection: $selectedCounterparty) {
                            Text("New counterparty").tag(Optional<String>.none)
                            if !store.data.loanContacts.isEmpty {
                                Section("Saved people") {
                                    ForEach(store.data.loanContacts) { contact in
                                        Text(contact.name).tag(Optional(contact.name))
                                    }
                                }
                            }
                            if !pastLoanCounterpartyNames(in: store.data).isEmpty {
                                Section("Past loan names") {
                                    ForEach(pastLoanCounterpartyNames(in: store.data), id: \.self) { name in
                                        Text(name).tag(Optional(name))
                                    }
                                }
                            }
                        }
                        if selectedCounterparty == nil {
                            TextField(counterpartyLabel, text: $counterparty)
                        }
                    }
                    if selectedCounterparty == nil {
                        NavigationLink {
                            LoanPeopleView(store: store)
                        } label: {
                            Label("Manage people", systemImage: "person.2")
                        }
                    }
                    if loan == nil {
                        if direction == .borrowed {
                            Picker("How did you get it?", selection: $fundingMethod) {
                                Text("Money received").tag(LoanFundingMethod.cashMovement)
                                Text("Expense paid for me").tag(LoanFundingMethod.expensePaidForBorrower)
                            }
                        }
                        CurrencyInputField(amountLabel, text: $amountText, currency: $loanCurrency)
                        DatePicker("Started", selection: $startedAt, in: Date.distantPast...Date.now, displayedComponents: .date)
                    }
                    TextField("Description (optional)", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Add due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due date", selection: $dueDate, displayedComponents: .date)
                    }
                }

                if loan == nil {
                    if usesCashMovement {
                        Section(direction == .lent ? "Money given from" : "Money received into") {
                            if eligibleAccounts.isEmpty {
                                Text("Add a cash or bank account before creating a loan.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Account", selection: selectedAccountBinding) {
                                    ForEach(eligibleAccounts) { account in
                                        Text("\(account.name) · \(account.currency.rawValue)")
                                            .tag(Optional(account.id))
                                    }
                                }
                            }
                            if let cashMovementAmount {
                                LabeledContent("Cash movement") {
                                    Text(cashMovementAmount.formatted)
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                }
                                if let fundingRate {
                                    Text(fundingRate.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if needsFundingRate {
                                Text("Add an exchange rate in More → Exchange Rates to record the funding movement.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            Text("The loan uses its own currency. Funding is converted to the selected cash account with a saved exchange rate, and principal stays out of income and expense totals.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Expense paid for you") {
                            Text("This records what they paid on your behalf as a debt. No cash account balance or expense total changes.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle(loan == nil ? "New loan" : "Edit loan")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasUnsavedChanges)
            .navigationBarBackButtonHidden(hasUnsavedChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .alert("Loan not saved", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Discard loan changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
    }

    private var hasUnsavedChanges: Bool {
        (selectedCounterparty ?? counterparty) != (loan?.counterparty ?? "")
            || descriptionText != (loan?.description ?? "")
            || hasDueDate != (loan?.dueDate != nil)
            || (hasDueDate && dueDate != loan?.dueDate)
            || !amountText.isEmpty
            || direction != (loan?.direction ?? .borrowed)
            || fundingMethod != .cashMovement
            || startedAt != initialStartDate
            || selectedAccountID != initialAccountID
            || loanCurrency != initialCurrency
    }

    private var counterpartyLabel: String {
        loan?.direction.counterpartyLabel ?? direction.counterpartyLabel
    }

    private var amountLabel: String {
        if direction == .lent { return "Total amount given" }
        return fundingMethod == .expensePaidForBorrower ? "Total paid for you" : "Total amount received"
    }

    private var usesCashMovement: Bool {
        direction == .lent || fundingMethod == .cashMovement
    }

    private var cleanedDescription: String? {
        let value = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var counterpartyNames: [String] {
        loanCounterpartyNames(in: store.data)
    }

    private var eligibleAccounts: [Account] {
        store.activeAccounts.filter { !$0.isArchived && ($0.type == .cash || $0.type == .bankAccount) }
    }

    private var selectedAccount: Account? {
        eligibleAccounts.first { $0.id == selectedAccountID }
    }

    private var fundingRate: ExchangeRate? {
        guard usesCashMovement,
              let selectedAccount,
              selectedAccount.currency != loanCurrency else { return nil }
        return store.exchangeRate(base: loanCurrency, quote: selectedAccount.currency)
    }

    private var needsFundingRate: Bool {
        usesCashMovement && (selectedAccount.map { $0.currency != loanCurrency } ?? false)
    }

    private var cashMovementAmount: Money? {
        guard usesCashMovement,
              let selectedAccount,
              let principalAmount = Money.parse(amountText, currency: loanCurrency),
              let minorUnits = financeConvertedMinorUnits(
                  principalAmount,
                  to: selectedAccount.currency,
                  using: fundingRate
              ) else { return nil }
        return Money(currency: selectedAccount.currency, minorUnits: minorUnits)
    }

    private var selectedAccountBinding: Binding<UUID?> {
        Binding(get: { selectedAccountID }, set: { selectedAccountID = $0 })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        let party = (selectedCounterparty ?? counterparty).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !party.isEmpty else {
            errorMessage = "Enter the person or organization for this loan."
            return
        }
        let contactID = loanContactID(for: party, in: store.data)
        if var existing = loan {
            existing.counterparty = party
            existing.counterpartyContactID = contactID
            existing.description = cleanedDescription
            existing.dueDate = hasDueDate ? dueDate : nil
            guard store.updateLoan(existing) else {
                errorMessage = store.lastActionStatus ?? "The loan could not be updated."
                return
            }
            onSave?()
            dismiss()
            return
        }

        guard let amount = Money.parse(amountText, currency: loanCurrency), amount.minorUnits > 0 else {
            errorMessage = "Enter a positive loan amount."
            return
        }
        let account: Account?
        let movement: MoneyMovement?
        if usesCashMovement {
            guard let selectedAccount else {
                errorMessage = "Choose a cash or bank account."
                return
            }
            guard let cashMovementAmount, cashMovementAmount.minorUnits > 0 else {
                errorMessage = needsFundingRate && fundingRate == nil
                    ? "Add an exchange rate in More → Exchange Rates to fund this loan in a different currency."
                    : "Enter a positive amount and choose a cash or bank account."
                return
            }
            account = selectedAccount
            movement = MoneyMovement(accountID: selectedAccount.id, money: cashMovementAmount)
        } else {
            account = nil
            movement = nil
        }
        let dueDate = hasDueDate ? self.dueDate : nil

        let loanID = UUID()
        let transactionID = UUID()
        let loan = Loan(
            id: loanID,
            counterparty: party,
            counterpartyContactID: contactID,
            description: cleanedDescription,
            direction: direction,
            currency: amount.currency,
            startingAmount: amount,
            startedAt: startedAt,
            dueDate: dueDate,
            settlementAccountID: account?.id,
            fundingTransactionID: transactionID
        )
        let transaction = LedgerTransaction(
            id: transactionID,
            date: startedAt,
            note: direction == .lent
                ? "Loan to \(party)"
                : fundingMethod == .expensePaidForBorrower
                    ? "Expense paid for by \(party)"
                    : "Loan from \(party)",
            kind: .transfer,
            categoryID: nil,
            outflows: direction == .lent ? movement.map { [$0] } ?? [] : [],
            inflows: direction == .borrowed ? movement.map { [$0] } ?? [] : [],
            exchangeRate: usesCashMovement ? fundingRate : nil,
            loanID: loanID,
            loanActivity: .funding,
            loanFundingMethod: usesCashMovement ? .cashMovement : .expensePaidForBorrower,
            loanPrincipalAmount: amount
        )
        guard store.addLoan(loan, fundingTransaction: transaction) else {
            errorMessage = store.lastActionStatus ?? "The loan could not be saved."
            return
        }
        onSave?()
        dismiss()
    }
}

private enum LoanDetailDestination {
    case editLoan
    case recordPayment
    case editPayment(UUID)
}

@MainActor
struct LoanDetailView: View {
    @ObservedObject var store: LedgerStore
    @EnvironmentObject private var security: AppSecurityService
    let loanID: UUID
    let showsCloseButton: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var destination: LoanDetailDestination?
    @State private var deletingPayment: LoanPayment?
    @State private var settlementToUndoID: UUID?
    @State private var errorMessage: String?
    @State private var isConfirmingResolution = false
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(store: LedgerStore, loanID: UUID, showsCloseButton: Bool = false) {
        _store = ObservedObject(wrappedValue: store)
        self.loanID = loanID
        self.showsCloseButton = showsCloseButton
    }

    private var loan: Loan? { store.loan(with: loanID) }

    var body: some View {
        Group {
            if let loan {
                detail(loan)
            } else {
                ContentUnavailableView("Loan unavailable", systemImage: "arrow.left.arrow.right.circle")
            }
        }
        .navigationTitle(loan?.counterparty ?? "Loan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            BalanceVisibilityToolbarItem(security: security)
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    destination = .editLoan
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit loan")
            }
        }
        .navigationDestination(isPresented: destinationPresented) {
            destinationView
        }
        .alert("Loan action failed", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove this payment?",
            isPresented: deletingPaymentPresented,
            titleVisibility: .visible
        ) {
            Button("Remove payment", role: .destructive) {
                if let deletingPayment,
                   !store.deleteLoanPayment(loanID: loanID, paymentID: deletingPayment.id) {
                    errorMessage = store.lastActionStatus ?? "The payment could not be removed."
                }
                deletingPayment = nil
            }
            Button("Cancel", role: .cancel) { deletingPayment = nil }
        }
        .confirmationDialog(
            "Undo this person settlement?",
            isPresented: settlementUndoPresented,
            titleVisibility: .visible
        ) {
            Button("Undo settlement", role: .destructive, action: undoPersonSettlement)
            Button("Cancel", role: .cancel) { settlementToUndoID = nil }
        } message: {
            Text("This removes the settlement from all linked loans and reverses its account movements.")
        }
    }

    private func detail(_ loan: Loan) -> some View {
        ScrollView(showsIndicators: false) {
            PocketGlassContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(loan.direction.displayName, systemImage: loan.direction == .lent ? "arrow.up.right" : "arrow.down.left")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                            Spacer()
                            Text(loan.currency.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PocketLedgerTheme.accent)
                        }
                        Text(loan.counterparty)
                            .font(.title3.weight(.semibold))
                        if let description = loan.description,
                           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                        ProtectedAmountText(value: loan.outstandingAmount.formatted, isRevealed: areBalancesRevealed)
                            .font(.largeTitle.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(loan.resolvedAt == nil
                            ? (loan.isSettled ? "Settled" : loan.payments.isEmpty ? "Outstanding" : "Partially settled")
                            : "Resolved without payment")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(loan.isSettled ? PocketLedgerTheme.textSecondary : PocketLedgerTheme.income)
                        if loan.resolvedAt == nil, !loan.payments.isEmpty {
                            let settledMinorUnits = loan.payments.reduce(Int64.zero) { $0 + $1.amount.minorUnits }
                            ProtectedAmountText(
                                value: "Settled \(Money(currency: loan.currency, minorUnits: settledMinorUnits).formatted) of \(loan.startingAmount.formatted)",
                                isRevealed: areBalancesRevealed
                            )
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                            if areBalancesRevealed {
                                ProgressView(
                                    value: Double(settledMinorUnits),
                                    total: Double(loan.startingAmount.minorUnits)
                                )
                                    .tint(PocketLedgerTheme.accent)
                            }
                        }
                        if let resolvedAt = loan.resolvedAt {
                            Text("Resolved \(resolvedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }
                        if let dueDate = loan.dueDate {
                            Label("Due \(dueDate.formatted(date: .long, time: .omitted))", systemImage: "calendar")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                        if let account = loan.settlementAccountID.flatMap({ store.account(with: $0) }) {
                            Label("Cash account: \(account.name)", systemImage: account.type.systemImage)
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }
                        if let transactionID = loan.fundingTransactionID,
                           let fundingTransaction = store.data.transactions.first(where: { $0.id == transactionID }),
                           fundingTransaction.loanFundingMethod == .expensePaidForBorrower {
                            LabeledContent("Paid on your behalf") {
                                ProtectedAmountText(
                                    value: loan.startingAmount.formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                        } else if let funding = originalFunding(for: loan) {
                            LabeledContent(loan.direction == .lent ? "Amount given" : "Amount received") {
                                ProtectedAmountText(
                                    value: funding.amount.formatted,
                                    isRevealed: areBalancesRevealed
                                )
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            Text("Through \(funding.account.name)")
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textTertiary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pocketGroupedSurface(cornerRadius: 20)

                    if !loan.isSettled {
                        Button {
                            destination = .recordPayment
                        } label: {
                            Label(loan.direction == .lent ? "Record collection" : "Record repayment", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PocketLedgerTheme.accent)

                        Button {
                            isConfirmingResolution = true
                        } label: {
                            Label("Resolve without payment", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .confirmationDialog(
                            "Resolve this loan without payment?",
                            isPresented: $isConfirmingResolution,
                            titleVisibility: .visible
                        ) {
                            Button("Resolve loan", role: .destructive, action: resolveWithoutPayment)
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This closes the loan without recording a repayment or changing any account balance.")
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Payment history")
                            .font(.headline)
                        if loan.payments.isEmpty {
                            Text("No payments recorded yet.")
                                .font(.subheadline)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(loan.payments.sorted { $0.date > $1.date }) { payment in
                                paymentRow(payment)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pocketGroupedSurface(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Started \(loan.startedAt.formatted(date: .abbreviated, time: .omitted))")
                        ProtectedAmountText(value: "Original total \(loan.startingAmount.formatted)", isRevealed: areBalancesRevealed)
                    }
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .scrollIndicators(.hidden)
        .pocketScreen()
    }

    private func paymentRow(_ payment: LoanPayment) -> some View {
        let transaction = payment.transactionID.flatMap { id in
            store.data.transactions.first { $0.id == id }
        }
        let movement = transaction.flatMap { ($0.outflows + $0.inflows).first }
        let account = movement.flatMap { store.account(with: $0.accountID) }
        return HStack(spacing: 10) {
            Image(systemName: payment.isSettlementOffset ? "arrow.left.arrow.right.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(payment.isSettlementOffset ? PocketLedgerTheme.textSecondary : PocketLedgerTheme.income)
            VStack(alignment: .leading, spacing: 3) {
                Text(payment.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.medium))
                if payment.isSettlementOffset {
                    Text("Offset against reciprocal loans")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                } else if payment.settlementID != nil {
                    Text("Person settlement")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                if let account {
                    Text("Via \(account.name)")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            ProtectedAmountText(value: payment.amount.formatted, isRevealed: areBalancesRevealed)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if let settlementID = payment.settlementID {
                Menu {
                    Button("Undo person settlement", systemImage: "arrow.uturn.backward", role: .destructive) {
                        settlementToUndoID = settlementID
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settlement actions")
            } else {
                Menu {
                    Button("Edit payment", systemImage: "pencil") { destination = .editPayment(payment.id) }
                    Button("Remove payment", systemImage: "trash", role: .destructive) { deletingPayment = payment }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Payment actions")
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PocketLedgerTheme.divider).frame(height: 1)
        }
    }

    private func originalFunding(for loan: Loan) -> (amount: Money, account: Account)? {
        guard let transactionID = loan.fundingTransactionID,
              let transaction = store.data.transactions.first(where: { $0.id == transactionID }),
              let movement = (transaction.outflows + transaction.inflows).first,
              let account = store.account(with: movement.accountID) else {
            return nil
        }
        return (movement.money, account)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var settlementUndoPresented: Binding<Bool> {
        Binding(get: { settlementToUndoID != nil }, set: { if !$0 { settlementToUndoID = nil } })
    }

    private func resolveWithoutPayment() {
        guard store.resolveLoans(ids: [loanID]) else {
            errorMessage = store.lastActionStatus ?? "The loan could not be resolved."
            return
        }
    }

    private func undoPersonSettlement() {
        guard let settlementToUndoID else { return }
        if !store.deleteLoanSettlement(id: settlementToUndoID) {
            errorMessage = store.lastActionStatus ?? "The person settlement could not be undone."
        }
        self.settlementToUndoID = nil
    }

    private var destinationPresented: Binding<Bool> {
        Binding(get: { destination != nil }, set: { if !$0 { destination = nil } })
    }

    @ViewBuilder
    private var destinationView: some View {
        if let destination, let loan {
            switch destination {
            case .editLoan:
                LoanEditor(store: store, loan: loan, wrapsInNavigationStack: false)
            case .recordPayment:
                LoanPaymentEditor(store: store, loan: loan)
            case .editPayment(let paymentID):
                if let payment = loan.payments.first(where: { $0.id == paymentID }),
                   let transactionID = payment.transactionID,
                   let transaction = store.data.transactions.first(where: { $0.id == transactionID }) {
                    LoanPaymentEditor(store: store, loan: loan, payment: payment, transaction: transaction)
                        .modifier(FinancialAmountEditorCover(security: security))
                } else {
                    ContentUnavailableView("Payment unavailable", systemImage: "exclamationmark.circle")
                }
            }
        }
    }

    private var deletingPaymentPresented: Binding<Bool> {
        Binding(get: { deletingPayment != nil }, set: { if !$0 { deletingPayment = nil } })
    }
}

@MainActor
private struct LoanPaymentEditor: View {
    @ObservedObject var store: LedgerStore
    let loan: Loan
    let payment: LoanPayment?
    let transaction: LedgerTransaction?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: UUID?
    @State private var amountText: String
    @State private var date: Date
    @State private var errorMessage: String?
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    init(
        store: LedgerStore,
        loan: Loan,
        payment: LoanPayment? = nil,
        transaction: LedgerTransaction? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.loan = loan
        self.payment = payment
        self.transaction = transaction
        let movement = transaction.flatMap { ($0.outflows + $0.inflows).first }
        let defaultAccount = loan.settlementAccountID
            ?? store.activeAccounts.first { $0.type == .cash || $0.type == .bankAccount }?.id
        let selectedID = movement?.accountID ?? defaultAccount
        _selectedAccountID = State(initialValue: selectedID)
        let selectedCurrency = store.activeAccounts.first { $0.id == selectedID }?.currency ?? loan.currency
        _amountText = State(initialValue: movement.map { selectedCurrency.formattedInput(minorUnits: $0.money.minorUnits) } ?? "")
        _date = State(initialValue: payment?.date ?? .now)
    }

    var body: some View {
        Form {
                Section(payment == nil ? "Payment" : "Edit payment") {
                    CurrencyInputField("Amount", text: $amountText, currency: paymentCurrency)
                    DatePicker("Date", selection: $date, in: Date.distantPast...Date.now, displayedComponents: .date)
                    Picker("Cash account", selection: selectedAccountBinding) {
                        ForEach(eligibleAccounts) { account in
                            Text("\(account.name) · \(account.currency.rawValue)").tag(Optional(account.id))
                        }
                    }
                }

                Section("Loan balance") {
                    LabeledContent("Outstanding") {
                        ProtectedAmountText(
                            value: loan.outstandingAmount.formatted,
                            isRevealed: areBalancesRevealed
                        )
                    }
                    if let principalAmount {
                        LabeledContent("Applied to loan") {
                            ProtectedAmountText(
                                value: principalAmount.formatted,
                                isRevealed: areBalancesRevealed
                            )
                        }
                    } else if needsExchangeRate {
                        Text("Add an exchange rate in More → Exchange Rates to record this payment in a different currency.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .pocketListSurface()
        .navigationTitle(payment == nil ? (loan.direction == .lent ? "Record collection" : "Record repayment") : "Edit payment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
        .alert("Payment not saved", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var eligibleAccounts: [Account] {
        store.activeAccounts.filter { !$0.isArchived && ($0.type == .cash || $0.type == .bankAccount) }
    }

    private var selectedAccount: Account? { eligibleAccounts.first { $0.id == selectedAccountID } }
    private var paymentCurrency: LedgerCurrency { selectedAccount?.currency ?? loan.currency }

    private var needsExchangeRate: Bool {
        selectedAccount.map { $0.currency != loan.currency } ?? false
    }

    private var selectedAccountBinding: Binding<UUID?> {
        Binding(get: { selectedAccountID }, set: { selectedAccountID = $0 })
    }

    private var rate: ExchangeRate? {
        guard paymentCurrency != loan.currency else { return nil }
        return store.exchangeRate(base: paymentCurrency, quote: loan.currency)
    }

    private var principalAmount: Money? {
        guard let cashAmount = Money.parse(amountText, currency: paymentCurrency),
              let minorUnits = financeConvertedMinorUnits(cashAmount, to: loan.currency, using: rate) else {
            return nil
        }
        return Money(currency: loan.currency, minorUnits: minorUnits)
    }

    private var canSave: Bool {
        guard let selectedAccount,
              let principalAmount,
              principalAmount.minorUnits > 0,
              date <= .now else { return false }
        let maximum = loan.outstandingAmount.minorUnits + (payment?.amount.minorUnits ?? 0)
        return principalAmount.minorUnits <= maximum
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        guard let account = selectedAccount,
              let cashAmount = Money.parse(amountText, currency: account.currency),
              let principalAmount,
              principalAmount.minorUnits > 0,
              date <= .now else {
            errorMessage = "Enter a valid payment and choose a cash or bank account."
            return
        }
        let maximum = loan.outstandingAmount.minorUnits + (payment?.amount.minorUnits ?? 0)
        guard principalAmount.minorUnits <= maximum else {
            errorMessage = "The payment cannot exceed the remaining loan balance."
            return
        }

        let paymentID = payment?.id ?? UUID()
        let transactionID = payment?.transactionID ?? UUID()
        let newPayment = LoanPayment(
            id: paymentID,
            date: date,
            amount: principalAmount,
            transactionID: transactionID
        )
        let oldMovement = transaction.flatMap { ($0.outflows + $0.inflows).first }
        let movement = MoneyMovement(
            id: oldMovement?.id ?? UUID(),
            accountID: account.id,
            money: cashAmount
        )
        let updatedTransaction = LedgerTransaction(
            id: transactionID,
            date: date,
            note: loan.direction == .lent ? "Loan collection from \(loan.counterparty)" : "Loan repayment to \(loan.counterparty)",
            kind: .transfer,
            categoryID: nil,
            outflows: loan.direction == .borrowed ? [movement] : [],
            inflows: loan.direction == .lent ? [movement] : [],
            exchangeRate: rate,
            attachmentIDs: transaction?.attachmentIDs ?? [],
            loanID: loan.id,
            loanPaymentID: paymentID,
            loanActivity: .payment,
            loanPrincipalAmount: principalAmount
        )

        let saved = payment == nil
            ? store.recordLoanPayment(newPayment, for: loan.id, transaction: updatedTransaction)
            : store.updateLoanPayment(newPayment, for: loan.id, transaction: updatedTransaction)
        guard saved else {
            errorMessage = store.lastActionStatus ?? "The payment could not be saved."
            return
        }
        dismiss()
    }
}

@MainActor
private struct LoanPeopleView: View {
    @ObservedObject var store: LedgerStore
    @State private var personToDelete: LoanContact?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if store.data.loanContacts.isEmpty {
                ContentUnavailableView(
                    "No saved people",
                    systemImage: "person.2",
                    description: Text("Add someone to reuse their name for future loans. Past loan names remain in history and are not saved people.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.data.loanContacts) { person in
                        NavigationLink {
                            LoanPersonEditorView(store: store, person: person)
                        } label: {
                            Label(person.name, systemImage: "person.crop.circle")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                personToDelete = person
                            }
                        }
                    }
                } footer: {
                    Text("This list contains saved people only. Names from past loans remain in loan history and picker suggestions.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .pocketScreen()
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    LoanPersonEditorView(store: store)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add person")
            }
        }
        .confirmationDialog(
            "Delete saved person?",
            isPresented: deletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete person", role: .destructive) {
                if let personToDelete {
                    delete(personToDelete)
                }
            }
            Button("Cancel", role: .cancel) { personToDelete = nil }
        } message: {
            Text("Related loans and payment history will remain in history with this name. Only the saved person will be removed.")
        }
        .alert("People action failed", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { personToDelete != nil },
            set: { if !$0 { personToDelete = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func delete(_ person: LoanContact) {
        personToDelete = nil
        do {
            try store.deleteLoanContact(id: person.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct LoanPersonEditorView: View {
    @ObservedObject var store: LedgerStore
    let person: LoanContact?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?

    init(store: LedgerStore, person: LoanContact? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.person = person
        _name = State(initialValue: person?.name ?? "")
    }

    var body: some View {
        Form {
            Section("Person") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
            }
        }
        .pocketListSurface()
        .navigationTitle(person == nil ? "Add person" : "Edit person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Person not saved", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func save() {
        let contact = LoanContact(
            id: person?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            if person == nil {
                try store.addLoanContact(contact)
            } else {
                try store.updateLoanContact(contact)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
