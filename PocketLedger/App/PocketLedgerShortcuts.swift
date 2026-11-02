import AppIntents
import Foundation

private func budgetStatusLines(in data: FinanceData) -> [String] {
    let month = Calendar.current.dateInterval(of: .month, for: .now)
    return data.budgets.map { budget in
        let spent = financeBudgetSpent(budget, in: data, interval: month)
        let allowance = financeBudgetAllowance(budget, in: data, interval: month)
        let category = data.categories.first(where: { $0.id == budget.categoryID })?.name ?? "Uncategorized"
        let remaining = Money(currency: budget.currency, minorUnits: allowance.minorUnits - spent.minorUnits)
        let remainingText = remaining.minorUnits >= 0
            ? "\(remaining.formatted) remaining"
            : "\(Money(currency: budget.currency, minorUnits: -remaining.minorUnits).formatted) over"
        return "\(category): \(spent.formatted) of \(allowance.formatted), \(remainingText)"
    }
}

struct GenerateBudgetSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Pocket Ledger Budget"
    static let description = IntentDescription("Summarizes this month's Pocket Ledger category budgets, using Apple Intelligence when available.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "The Pocket Ledger budgets are unavailable because the persistent database is unavailable."
            )
        }

        let data = storage.load()
        guard !storage.isCorrupted else {
            return .result(
                value: "Ledger unavailable",
                dialog: "Pocket Ledger could not read the saved budgets."
            )
        }

        let lines = budgetStatusLines(in: data)
        guard !lines.isEmpty else {
            return .result(value: "No budgets configured", dialog: "No Pocket Ledger budgets are configured.")
        }

        let summary = await FoundationModelService.generateBudgetSummary(for: lines)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct GetBudgetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Pocket Ledger Budgets"
    static let description = IntentDescription("Returns this month's spending against each Pocket Ledger category budget.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "The Pocket Ledger budgets are unavailable because the persistent database is unavailable."
            )
        }

        let data = storage.load()
        guard !storage.isCorrupted else {
            return .result(
                value: "Ledger unavailable",
                dialog: "Pocket Ledger could not read the saved budgets."
            )
        }

        let lines = budgetStatusLines(in: data)
        let summary = lines.isEmpty ? "No budgets configured." : lines.joined(separator: "\n")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct OpenTransactionTemplateIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Transaction from Pocket Ledger Template"
    static let description = IntentDescription("Opens a saved transaction template in Pocket Ledger so you can review and save it.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Transaction template")
    var template: FinanceTemplateEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start a transaction from \(\.$template)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(dialog: "Saved transaction templates are unavailable because the persistent database is unavailable.")
        }
        let data = storage.load()
        guard !storage.isCorrupted else {
            return .result(dialog: "Pocket Ledger could not read the saved transaction templates.")
        }
        guard let savedTemplate = data.templates.first(where: { $0.id == template.id }) else {
            return .result(dialog: "Pocket Ledger could not find that transaction template.")
        }

        await MainActor.run {
            FinanceIntentSearchRouter.shared.showTransactionTemplate(id: savedTemplate.id)
        }
        return .result(dialog: IntentDialog(stringLiteral: "Opening \(savedTemplate.name) so you can review and save it."))
    }
}

struct PocketLedgerShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetBalanceIntent(),
            phrases: [
                "How much money do I have in \(.applicationName)",
                "How much do I have in \(.applicationName)",
                "What is my total balance in \(.applicationName)",
                "Get my balance in \(.applicationName)",
                "What's my balance in \(.applicationName)",
                "Check my balance in \(.applicationName)",
                "Tell me my balance in \(.applicationName)"
            ],
            shortTitle: "Get Pocket Ledger Balance",
            systemImageName: "dollarsign.circle"
        )
        AppShortcut(
            intent: AddLedgerTransactionIntent(),
            phrases: [
                "Add a transaction in \(.applicationName)",
                "Add a transaction to \(\.$account) in \(.applicationName)",
                "Record a transaction in \(.applicationName)"
            ],
            shortTitle: "Add Pocket Ledger Transaction",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: GetAccountBalanceIntent(),
            phrases: [
                "Get the balance of \(\.$account) in \(.applicationName)",
                "Check an account balance in \(.applicationName)",
                "How much money is in \(\.$account) in \(.applicationName)"
            ],
            shortTitle: "Get Account Balance",
            systemImageName: "chart.bar.xaxis"
        )
        AppShortcut(
            intent: GetTransactionHistoryIntent(),
            phrases: [
                "Show my transactions for \(\.$period) in \(.applicationName)",
                "Show my \(\.$category) transactions in \(.applicationName)",
                "Find my transactions for \(\.$period) in \(.applicationName)"
            ],
            shortTitle: "Get Transaction History",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: GetSpendingSummaryIntent(),
            phrases: [
                "How much did I spend \(\.$period) in \(.applicationName)",
                "How much did I spend on \(\.$category) in \(.applicationName)",
                "Summarize my spending for \(\.$period) in \(.applicationName)"
            ],
            shortTitle: "Get Spending Summary",
            systemImageName: "chart.bar.doc.horizontal"
        )
        AppShortcut(
            intent: GetUpcomingCommitmentsIntent(),
            phrases: [
                "What's due \(\.$period) in \(.applicationName)",
                "What payments are due \(\.$period) in \(.applicationName)",
                "List my upcoming payments \(\.$period) in \(.applicationName)"
            ],
            shortTitle: "Upcoming Commitments",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: GetSavingsGoalProgressIntent(),
            phrases: [
                "Check my savings goals in \(.applicationName)",
                "How much is left for \(\.$goal) in \(.applicationName)",
                "How close am I to \(\.$goal) in \(.applicationName)"
            ],
            shortTitle: "Savings Goal Progress",
            systemImageName: "scope"
        )
        AppShortcut(
            intent: OpenTransactionTemplateIntent(),
            phrases: [
                "Start a transaction from \(\.$template) in \(.applicationName)",
                "Log a transaction from \(\.$template) in \(.applicationName)",
                "Use my \(\.$template) template in \(.applicationName)"
            ],
            shortTitle: "Use Transaction Template",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: GetBudgetStatusIntent(),
            phrases: [
                "Check my Pocket Ledger budgets in \(.applicationName)",
                "How are my budgets doing in \(.applicationName)",
                "Show my budget status in \(.applicationName)"
            ],
            shortTitle: "Check Budgets",
            systemImageName: "chart.bar.doc.horizontal"
        )
#if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            AppShortcut(
                intent: SearchPocketLedgerIntent(),
                phrases: [
                    "Search in \(.applicationName)",
                    "Find something in \(.applicationName)"
                ],
                shortTitle: "Search Pocket Ledger",
                systemImageName: "magnifyingglass"
            )
        }
#else
        if #available(iOS 17.0, *) {
            AppShortcut(
                intent: SearchPocketLedgerIntent(),
                phrases: [
                    "Search in \(.applicationName)",
                    "Find something in \(.applicationName)"
                ],
                shortTitle: "Search Pocket Ledger",
                systemImageName: "magnifyingglass"
            )
        }
#endif
    }
}
