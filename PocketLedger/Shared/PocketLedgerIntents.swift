import AppIntents
import Foundation
import WidgetKit

enum FinanceIntentQuickExpenseRequest {
    private static let storageKey = "pocketLedger.pendingQuickExpense"

    private struct PendingRequest: Codable {
        let amount: Money
        let note: String
    }

    static func stage(amountText: String, note: String) -> Money? {
        guard let amount = financeMoney(amountText, currency: .usd),
              let data = try? JSONEncoder().encode(PendingRequest(amount: amount, note: note)),
              let defaults = UserDefaults(suiteName: FinanceStorage.appGroupIdentifier) else { return nil }
        defaults.set(data, forKey: storageKey)
        return amount
    }

    static func consume() -> (amount: Money, note: String)? {
        guard let defaults = UserDefaults(suiteName: FinanceStorage.appGroupIdentifier),
              let data = defaults.data(forKey: storageKey) else { return nil }
        defaults.removeObject(forKey: storageKey)
        guard let request = try? JSONDecoder().decode(PendingRequest.self, from: data) else { return nil }
        return (request.amount, request.note)
    }
}

struct QuickExpenseControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Pocket Ledger Quick Expense"
    static let description = IntentDescription("Choose the USD amount used by the Pocket Ledger Control Center action.")

    @Parameter(title: "USD amount", default: "5")
    var amount: String
}

struct AddConfiguredExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Pocket Ledger Quick Expense"
    static let description = IntentDescription("Opens the configured USD expense in Pocket Ledger for review.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "USD amount")
    var amount: String

    init() {
        amount = "5"
    }

    init(amount: String) {
        self.amount = amount
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let money = FinanceIntentQuickExpenseRequest.stage(
            amountText: amount,
            note: "Quick control expense"
        ) else {
            return .result(
                value: "Quick expense unavailable",
                dialog: "Enter a positive USD amount to prepare this expense."
            )
        }
        return .result(
            value: money.formatted,
            dialog: "Review and save this \(money.formatted) expense in Pocket Ledger."
        )
    }
}

struct GetBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Balance"
    static let description = IntentDescription("Reads the current Pocket Ledger balances by currency.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "The Pocket Ledger persistent database is unavailable, so no balances can be read."
            )
        }

        let snapshot = storage.widgetSnapshot()
        return .result(
            value: snapshot.balanceSummary,
            dialog: "Your Pocket Ledger balances are \(snapshot.balanceSummary)."
        )
    }
}

struct GetCategoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Categories"
    static let description = IntentDescription("Returns all Pocket Ledger categories and subcategories.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<[FinanceCategoryEntity]> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: [],
                dialog: "Pocket Ledger categories are unavailable because the persistent database is unavailable."
            )
        }

        let data = storage.load()
        let categories = data.categories
            .filter { !$0.isArchived }
            .map { FinanceCategoryEntity(category: $0, categories: data.categories) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let summary = categories.isEmpty
            ? "Pocket Ledger has no categories yet."
            : "Pocket Ledger has " + String(categories.count) + " categories: " + categories.map { $0.path }.joined(separator: ", ") + "."

        return .result(
            value: categories,
            dialog: IntentDialog(stringLiteral: summary)
        )
    }
}

struct GetAccountsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Accounts"
    static let description = IntentDescription("Returns all Pocket Ledger accounts with their current balance, currency, and type.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<[FinanceAccountEntity]> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: [],
                dialog: "Pocket Ledger accounts are unavailable because the persistent database is unavailable."
            )
        }

        let data = storage.load()
        let accounts = data.accounts
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                FinanceAccountEntity(
                    account: $0,
                    balance: financeAccountBalance(for: $0, in: data)
                )
            }
        let summary = accounts.isEmpty
            ? "Pocket Ledger has no accounts yet."
            : "Pocket Ledger has " + String(accounts.count) + " accounts: " + accounts.map {
                "\($0.name) (\($0.balance))"
            }.joined(separator: ", ") + "."

        return .result(
            value: accounts,
            dialog: IntentDialog(stringLiteral: summary)
        )
    }
}

struct GetAccountBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pocket Ledger Account Balance"
    static let description = IntentDescription("Reads the current balance for one Pocket Ledger account.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Account", description: "The account whose balance should be read.")
    var account: FinanceAccountEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the balance of \(\.$account)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "The Pocket Ledger persistent database is unavailable, so the account balance cannot be read."
            )
        }

        let data = storage.load()
        guard let resolvedAccount = data.accounts.first(where: { $0.id == account.id && !$0.isArchived }) else {
            return .result(
                value: "Account unavailable",
                dialog: "Pocket Ledger could not find the selected account. Refresh the account list and try again."
            )
        }

        let balance = financeAccountBalance(for: resolvedAccount, in: data)
        let value = resolvedAccount.name + ": " + balance.formatted
        return .result(
            value: value,
            dialog: IntentDialog(stringLiteral: resolvedAccount.name + " has " + balance.formatted + ".")
        )
    }
}

struct AddLedgerTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Pocket Ledger Transaction"
    static let description = IntentDescription("Adds an expense, income, or transfer with account, category, note, change, and exchange-rate details.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Transaction type", description: "Choose expense, income, or transfer.")
    var kind: FinanceIntentTransactionKind

    @Parameter(title: "Account", description: "The account money leaves from or enters.")
    var account: FinanceAccountEntity

    @Parameter(title: "Amount", description: "The amount in the selected account's currency.")
    var amount: String

    @Parameter(title: "Category", description: "Optional category for an expense.")
    var category: FinanceCategoryEntity?

    @Parameter(title: "Destination account", description: "Use for a transfer or money returned after an expense.")
    var destinationAccount: FinanceAccountEntity?

    @Parameter(title: "Destination amount", description: "The amount entering the destination account.")
    var destinationAmount: String?

    @Parameter(title: "Note", description: "Optional note for the transaction.")
    var note: String?

    @Parameter(title: "Date", description: "Optional transaction date. Defaults to now.")
    var date: Date?

    @Parameter(title: "Bill total", description: "Optional expense total, which may use a different currency.")
    var amountDue: String?

    @Parameter(title: "Bill currency", description: "Currency for the optional bill total.")
    var amountDueCurrency: FinanceIntentCurrency?

    @Parameter(title: "Requested change", description: "Optional requested change amount in the destination currency.")
    var requestedChange: String?

    @Parameter(title: "Exchange rate", description: "Optional quote units per base unit for a mixed-currency transaction.")
    var exchangeRate: String?

    @Parameter(title: "Rate base currency", description: "Currency used as the exchange-rate base.")
    var rateBaseCurrency: FinanceIntentCurrency?

    @Parameter(title: "Rate quote currency", description: "Currency quoted by the exchange rate.")
    var rateQuoteCurrency: FinanceIntentCurrency?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a \(\.$kind) of \(\.$amount) to \(\.$account)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let storage = FinanceStorage(context: "app-intent")
        guard storage.isPersistent else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "The transaction was not saved because the persistent database is unavailable."
            )
        }

        let data = storage.load()
        guard let sourceAccount = data.accounts.first(where: { $0.id == account.id && !$0.isArchived }) else {
            return .result(
                value: "Account unavailable",
                dialog: "Pocket Ledger could not find the selected account. Refresh the account list and try again."
            )
        }
        guard let sourceMoney = financeMoney(amount, currency: sourceAccount.currency) else {
            return .result(
                value: "Invalid amount",
                dialog: "Enter a positive amount in \(sourceAccount.currency.rawValue)."
            )
        }

        let destination: Account?
        if let destinationAccount {
            guard let resolvedDestination = data.accounts.first(where: { $0.id == destinationAccount.id && !$0.isArchived }) else {
                return .result(
                    value: "Destination account unavailable",
                    dialog: "Pocket Ledger could not find the selected destination account. Refresh the account list and try again."
                )
            }
            destination = resolvedDestination
        } else {
            destination = nil
        }

        var outflows: [MoneyMovement] = []
        var inflows: [MoneyMovement] = []
        var changeAdjustment: ChangeAdjustment?

        switch kind.ledgerKind {
        case .expense:
            outflows = [MoneyMovement(accountID: sourceAccount.id, money: sourceMoney)]

            if let destination {
                guard let destinationAmount,
                      let destinationMoney = financeMoney(destinationAmount, currency: destination.currency) else {
                    return .result(
                        value: "Invalid destination amount",
                        dialog: "Enter a positive destination amount in \(destination.currency.rawValue) for returned money."
                    )
                }
                inflows = [MoneyMovement(accountID: destination.id, money: destinationMoney)]

                if let requestedChange {
                    guard let requestedMoney = financeMoney(
                        requestedChange,
                        currency: destination.currency,
                        allowsZero: true
                    ) else {
                        return .result(
                            value: "Invalid requested change",
                            dialog: "Enter a zero or positive requested change amount in \(destination.currency.rawValue)."
                        )
                    }
                    changeAdjustment = ChangeAdjustment(
                        requested: requestedMoney,
                        actual: destinationMoney
                    )
                }
            } else if destinationAmount != nil || requestedChange != nil {
                return .result(
                    value: "Destination account required",
                    dialog: "Choose a destination account when recording returned money or requested change."
                )
            }

        case .income:
            guard destination == nil, destinationAmount == nil, requestedChange == nil else {
                return .result(
                    value: "Invalid income parameters",
                    dialog: "Income uses only the selected account. Remove destination and change parameters."
                )
            }
            inflows = [MoneyMovement(accountID: sourceAccount.id, money: sourceMoney)]

        case .transfer:
            guard let destination else {
                return .result(
                    value: "Destination account required",
                    dialog: "Choose a destination account for a transfer."
                )
            }
            guard requestedChange == nil else {
                return .result(
                    value: "Invalid transfer parameters",
                    dialog: "Requested change is only available for expenses."
                )
            }

            let destinationMoney: Money
            if let destinationAmount {
                guard let parsedDestination = financeMoney(destinationAmount, currency: destination.currency) else {
                    return .result(
                        value: "Invalid destination amount",
                        dialog: "Enter a positive destination amount in \(destination.currency.rawValue)."
                    )
                }
                destinationMoney = parsedDestination
            } else {
                guard sourceAccount.currency == destination.currency else {
                    return .result(
                        value: "Destination amount required",
                        dialog: "Enter a destination amount when transferring between different currencies."
                    )
                }
                destinationMoney = Money(
                    currency: destination.currency,
                    minorUnits: sourceMoney.minorUnits
                )
            }

            outflows = [MoneyMovement(accountID: sourceAccount.id, money: sourceMoney)]
            inflows = [MoneyMovement(accountID: destination.id, money: destinationMoney)]
        }

        guard category == nil || kind.ledgerKind == .expense else {
            return .result(
                value: "Invalid category",
                dialog: "Categories can only be attached to expenses."
            )
        }
        if let category,
           !data.categories.contains(where: { $0.id == category.id }) {
            return .result(
                value: "Category unavailable",
                dialog: "Pocket Ledger could not find the selected category. Refresh the category list and try again."
            )
        }

        var parsedAmountDue: Money?
        if let amountDue {
            guard kind.ledgerKind == .expense else {
                return .result(
                    value: "Invalid bill total",
                    dialog: "A bill total can only be attached to an expense."
                )
            }
            let dueCurrency = amountDueCurrency?.ledgerCurrency ?? sourceAccount.currency
            guard let dueMoney = financeMoney(amountDue, currency: dueCurrency) else {
                return .result(
                    value: "Invalid bill total",
                    dialog: "Enter a positive bill total in \(dueCurrency.rawValue)."
                )
            }
            parsedAmountDue = dueMoney
        } else {
            parsedAmountDue = nil
        }

        let movementCurrencies = LedgerCurrency.allCases.filter { currency in
            (outflows + inflows).contains { $0.money.currency == currency }
        }
        var parsedExchangeRate: ExchangeRate?
        if let exchangeRate {
            guard movementCurrencies.count > 1,
                  let rate = financePositiveDecimal(exchangeRate) else {
                return .result(
                    value: "Invalid exchange rate",
                    dialog: "Enter a positive exchange rate only when the transaction uses multiple currencies."
                )
            }

            let baseCurrency = rateBaseCurrency?.ledgerCurrency ?? movementCurrencies[0]
            let quoteCurrency = rateQuoteCurrency?.ledgerCurrency
                ?? movementCurrencies.first(where: { $0 != baseCurrency })
            guard let quoteCurrency,
                  baseCurrency != quoteCurrency,
                  movementCurrencies.contains(baseCurrency),
                  movementCurrencies.contains(quoteCurrency) else {
                return .result(
                    value: "Invalid exchange-rate currencies",
                    dialog: "Choose two currencies used by this mixed-currency transaction."
                )
            }
            parsedExchangeRate = ExchangeRate(
                baseCurrency: baseCurrency,
                quoteCurrency: quoteCurrency,
                quoteUnitsPerBaseUnit: rate
            )
        } else {
            parsedExchangeRate = nil
        }

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transaction = LedgerTransaction(
            date: date ?? .now,
            note: trimmedNote.isEmpty ? kind.ledgerKind.displayName : trimmedNote,
            kind: kind.ledgerKind,
            categoryID: category?.id,
            amountDue: parsedAmountDue,
            outflows: outflows,
            inflows: inflows,
            exchangeRate: parsedExchangeRate,
            changeAdjustment: changeAdjustment
        )

        guard storage.appendTransaction(transaction) else {
            return .result(
                value: "Persistent database unavailable",
                dialog: "The transaction was not saved because the persistent database is unavailable."
            )
        }

        await FinanceIntentIndexing.shared.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: "BalanceWidget")
        let summary = financeTransactionSummary(transaction)
        return .result(
            value: summary,
            dialog: "Saved \(summary)."
        )
    }
}

private func financeMoney(
    _ rawValue: String,
    currency: LedgerCurrency,
    allowsZero: Bool = false
) -> Money? {
    let normalized = rawValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: "")
    guard !normalized.isEmpty,
          let amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
        return nil
    }

    let parsedValue = NSDecimalNumber(decimal: amount).stringValue
    guard let money = Money.parse(parsedValue, currency: currency) else {
        return nil
    }

    if allowsZero {
        return money.minorUnits >= 0 ? money : nil
    }
    return money.minorUnits > 0 ? money : nil
}

private func financePositiveDecimal(_ rawValue: String) -> Decimal? {
    let normalized = rawValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: "")
    guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
          value > 0 else {
        return nil
    }
    return value
}

private func financeTransactionSummary(_ transaction: LedgerTransaction) -> String {
    let outflowText = transaction.outflows.map { $0.money.formatted }.joined(separator: " + ")
    let inflowText = transaction.inflows.map { $0.money.formatted }.joined(separator: " + ")
    let movementText: String

    if outflowText.isEmpty {
        movementText = "+ \(inflowText)"
    } else if inflowText.isEmpty {
        movementText = "− \(outflowText)"
    } else {
        movementText = "\(outflowText) → \(inflowText)"
    }

    return "\(transaction.kind.displayName): \(movementText)\(transaction.note.isEmpty ? "" : " (\(transaction.note))")"
}
