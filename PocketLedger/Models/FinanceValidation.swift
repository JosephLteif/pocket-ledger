import Foundation

enum FinanceTransactionValidationError: LocalizedError, Equatable {
    case noMovements
    case missingMovementAccount
    case archivedMovementAccount
    case movementCurrencyMismatch
    case nonPositiveMovement
    case missingCategory
    case archivedCategory
    case invalidAmountDue
    case invalidChange
    case missingAttachment
    case unbalancedTransfer
    case missingExchangeRate
    case invalidLoanActivity

    var errorDescription: String? {
        switch self {
        case .noMovements:
            return "Add at least one account movement."
        case .missingMovementAccount:
            return "Every movement must use an existing account."
        case .archivedMovementAccount:
            return "Choose an active account for this transaction."
        case .movementCurrencyMismatch:
            return "A movement amount must use its account's currency, or include a valid exchange rate."
        case .nonPositiveMovement:
            return "Movement amounts must be greater than zero."
        case .missingCategory:
            return "Choose an existing category or leave the expense uncategorized."
        case .archivedCategory:
            return "Choose an active category for this transaction."
        case .invalidAmountDue:
            return "The bill total must be greater than zero."
        case .invalidChange:
            return "Requested and actual change must use the same currency and cannot be negative."
        case .missingAttachment:
            return "Every transaction attachment must exist in the ledger."
        case .unbalancedTransfer:
            return "A same-currency transfer must send and receive the same amount."
        case .missingExchangeRate:
            return "Add an exchange rate for this cross-currency transaction."
        case .invalidLoanActivity:
            return "Loan activity must be linked to a valid loan and use one matching cash movement."
        }
    }
}

enum FinanceTransactionValidator {
    static func validate(
        _ transaction: LedgerTransaction,
        in data: FinanceData,
        allowArchivedReferences: Bool = false
    ) -> FinanceTransactionValidationError? {
        let movements = transaction.outflows + transaction.inflows
        guard !movements.isEmpty else { return .noMovements }

        let isLoanActivity = transaction.loanID != nil
            || transaction.loanPaymentID != nil
            || transaction.loanActivity != nil
            || transaction.loanPrincipalAmount != nil
        if isLoanActivity, !isValidLoanActivity(transaction, in: data) {
            return .invalidLoanActivity
        }

        for movement in movements {
            guard let account = data.accounts.first(where: { $0.id == movement.accountID }) else {
                return .missingMovementAccount
            }
            if account.isArchived && !allowArchivedReferences {
                return .archivedMovementAccount
            }
            if movement.money.currency != account.currency,
               financeConvertedMinorUnits(
                   movement.money,
                   to: account.currency,
                   using: transaction.exchangeRate
               ) == nil {
                return .missingExchangeRate
            }
            guard movement.money.minorUnits > 0 else {
                return .nonPositiveMovement
            }
        }

        switch transaction.kind {
        case .expense:
            guard !transaction.outflows.isEmpty else { return .noMovements }
            if let categoryID = transaction.categoryID {
                guard let category = data.categories.first(where: { $0.id == categoryID }) else {
                    return .missingCategory
                }
                if category.isArchived && !allowArchivedReferences {
                    return .archivedCategory
                }
            }
        case .income:
            guard !transaction.inflows.isEmpty else { return .noMovements }
        case .transfer:
            guard transaction.loanID != nil
                    || (!transaction.outflows.isEmpty && !transaction.inflows.isEmpty) else {
                return .noMovements
            }
        }

        if let amountDue = transaction.amountDue, amountDue.minorUnits <= 0 {
            return .invalidAmountDue
        }

        if let change = transaction.changeAdjustment {
            guard change.requested.currency == change.actual.currency,
                  change.requested.minorUnits >= 0,
                  change.actual.minorUnits >= 0 else {
                return .invalidChange
            }
        }

        guard transaction.attachmentIDs.allSatisfy({ attachmentID in
            data.attachments.contains { $0.id == attachmentID }
        }) else {
            return .missingAttachment
        }

        let currencies = Set(movements.map { $0.money.currency })
        if transaction.kind == .transfer, transaction.loanID == nil {
            if currencies.count == 1 {
                let outflowTotal = transaction.outflows.reduce(Int64.zero) { $0 + $1.money.minorUnits }
                let inflowTotal = transaction.inflows.reduce(Int64.zero) { $0 + $1.money.minorUnits }
                guard outflowTotal == inflowTotal else { return .unbalancedTransfer }
            } else if transaction.exchangeRate == nil {
                return .missingExchangeRate
            }
        }

        return nil
    }

    private static func isValidLoanActivity(
        _ transaction: LedgerTransaction,
        in data: FinanceData
    ) -> Bool {
        guard transaction.kind == .transfer,
              let loanID = transaction.loanID,
              let activity = transaction.loanActivity,
              let principalAmount = transaction.loanPrincipalAmount,
              principalAmount.minorUnits > 0,
              transaction.categoryID == nil,
              transaction.amountDue == nil,
              transaction.changeAdjustment == nil,
              transaction.outflows.count + transaction.inflows.count == 1,
              let loan = data.loans.first(where: { $0.id == loanID }),
              principalAmount.currency == loan.currency,
              let movement = (transaction.outflows + transaction.inflows).first,
              let movementAccount = data.accounts.first(where: { $0.id == movement.accountID }),
              movementAccount.type == .cash || movementAccount.type == .bankAccount,
              financeConvertedMinorUnits(
                  movement.money,
                  to: loan.currency,
                  using: transaction.exchangeRate
              ) == principalAmount.minorUnits else {
            return false
        }

        switch activity {
        case .funding:
            guard transaction.loanPaymentID == nil,
                  loan.fundingTransactionID == transaction.id,
                  transaction.date == loan.startedAt,
                  loan.settlementAccountID == movement.accountID else {
                return false
            }
            return loan.direction == .lent
                ? !transaction.outflows.isEmpty
                : !transaction.inflows.isEmpty
        case .payment:
            guard let paymentID = transaction.loanPaymentID,
                  let payment = loan.payments.first(where: { $0.id == paymentID }),
                  payment.transactionID == transaction.id,
                  payment.date == transaction.date,
                  payment.amount == principalAmount else {
                return false
            }
            return loan.direction == .lent
                ? !transaction.inflows.isEmpty
                : !transaction.outflows.isEmpty
        }
    }
}

enum FinanceDataValidationError: LocalizedError, Equatable {
    case duplicateIDs(String)
    case accountCurrencyMismatch(String)
    case categoryParentMissing(String)
    case categoryCycle(String)
    case invalidTransaction(index: Int, error: FinanceTransactionValidationError)
    case invalidScheduledTransaction(index: Int, error: FinanceTransactionValidationError)
    case invalidScheduleRule(index: Int)
    case invalidTemplate(index: Int, error: FinanceTransactionValidationError)
    case invalidBudget(index: Int)
    case invalidExchangeRate(index: Int)
    case invalidLoan(String)

    var errorDescription: String? {
        switch self {
        case .duplicateIDs(let collection):
            return "The backup contains duplicate IDs in \(collection)."
        case .accountCurrencyMismatch(let accountName):
            return "Account \"\(accountName)\" has an opening balance in the wrong currency."
        case .categoryParentMissing(let categoryName):
            return "Category \"\(categoryName)\" refers to a missing parent category."
        case .categoryCycle(let categoryName):
            return "Category \"\(categoryName)\" is part of a parent cycle."
        case .invalidTransaction(let index, let error):
            return "Transaction \(index + 1) is invalid: \(error.localizedDescription)"
        case .invalidScheduledTransaction(let index, let error):
            return "Scheduled transaction \(index + 1) is invalid: \(error.localizedDescription)"
        case .invalidScheduleRule(let index):
            return "Scheduled transaction \(index + 1) has an invalid monthly recurrence rule."
        case .invalidTemplate(let index, let error):
            return "Template \(index + 1) is invalid: \(error.localizedDescription)"
        case .invalidBudget(let index):
            return "Budget \(index + 1) has a missing category, invalid amount, or currency mismatch."
        case .invalidExchangeRate(let index):
            return "Exchange rate \(index + 1) is invalid."
        case .invalidLoan(let counterparty):
            return "Loan with \(counterparty) has invalid amounts, references, or payment history."
        }
    }
}

enum FinanceDataValidator {
    static func validate(_ data: FinanceData, allowArchivedReferences: Bool = true) -> FinanceDataValidationError? {
        if hasDuplicateIDs(data.accounts.map(\.id)) {
            return .duplicateIDs("accounts")
        }
        if hasDuplicateIDs(data.categories.map(\.id)) {
            return .duplicateIDs("categories")
        }
        if hasDuplicateIDs(data.transactions.map(\.id)) {
            return .duplicateIDs("transactions")
        }
        if hasDuplicateIDs(data.loans.map(\.id)) {
            return .duplicateIDs("loans")
        }
        if hasDuplicateIDs(data.loans.flatMap { $0.payments.map(\.id) }) {
            return .duplicateIDs("loan payments")
        }
        if hasDuplicateIDs(data.scheduledTransactions.map(\.id)) {
            return .duplicateIDs("scheduled transactions")
        }
        if hasDuplicateIDs(data.budgets.map(\.id)) {
            return .duplicateIDs("budgets")
        }
        if hasDuplicateIDs(data.templates.map(\.id)) {
            return .duplicateIDs("templates")
        }
        if hasDuplicateIDs(data.attachments.map(\.id)) {
            return .duplicateIDs("attachments")
        }

        for account in data.accounts where account.openingBalance.currency != account.currency {
            return .accountCurrencyMismatch(account.name)
        }

        for accountID in data.managedLegacyLoanAccountIDs {
            guard let account = data.accounts.first(where: { $0.id == accountID }),
                  account.type == .loan,
                  account.isArchived,
                  !account.includeInTotals else {
                return .invalidLoan("legacy account")
            }
        }

        for loan in data.loans {
            let paymentTotal = loan.payments.reduce(Int64.zero) { $0 + $1.amount.minorUnits }
            guard !loan.counterparty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  loan.startingAmount.currency == loan.currency,
                  loan.startingAmount.minorUnits > 0,
                  paymentTotal <= loan.startingAmount.minorUnits,
                  loan.payments.allSatisfy({
                      $0.amount.currency == loan.currency
                          && $0.amount.minorUnits > 0
                  }) else {
                return .invalidLoan(loan.counterparty)
            }
            if let settlementAccountID = loan.settlementAccountID {
                guard let account = data.accounts.first(where: { $0.id == settlementAccountID }),
                      account.type == .cash || account.type == .bankAccount else {
                    return .invalidLoan(loan.counterparty)
                }
            }
            if let legacyAccountID = loan.legacyAccountID {
                guard let account = data.accounts.first(where: { $0.id == legacyAccountID }),
                      account.type == .loan,
                      account.isArchived,
                      !account.includeInTotals,
                      data.managedLegacyLoanAccountIDs.contains(legacyAccountID),
                      loan.fundingTransactionID == nil else {
                    return .invalidLoan(loan.counterparty)
                }
            } else if loan.fundingTransactionID == nil {
                return .invalidLoan(loan.counterparty)
            }
            guard loan.payments.allSatisfy({ payment in
                data.transactions.contains(where: {
                    $0.id == payment.transactionID
                        && $0.loanID == loan.id
                        && $0.loanPaymentID == payment.id
                        && $0.loanActivity == .payment
                        && $0.loanPrincipalAmount == payment.amount
                        && $0.date == payment.date
                })
            }) else {
                return .invalidLoan(loan.counterparty)
            }
            if let fundingTransactionID = loan.fundingTransactionID,
               !data.transactions.contains(where: {
                   $0.id == fundingTransactionID
                       && $0.loanID == loan.id
                       && $0.loanActivity == .funding
               }) {
                return .invalidLoan(loan.counterparty)
            }
        }

        let categoriesByID = Dictionary(uniqueKeysWithValues: data.categories.map { ($0.id, $0) })
        for category in data.categories {
            if let parentID = category.parentID,
               categoriesByID[parentID] == nil {
                return .categoryParentMissing(category.name)
            }

            var visited: Set<UUID> = []
            var currentID: UUID? = category.id
            while let id = currentID {
                guard visited.insert(id).inserted else {
                    return .categoryCycle(category.name)
                }
                currentID = categoriesByID[id]?.parentID
            }
        }

        for (index, transaction) in data.transactions.enumerated() {
            if let error = FinanceTransactionValidator.validate(
                transaction,
                in: data,
                allowArchivedReferences: allowArchivedReferences
            ) {
                return .invalidTransaction(index: index, error: error)
            }
        }

        for (index, scheduledTransaction) in data.scheduledTransactions.enumerated() {
            if scheduledTransaction.recurrenceDay < 1 || scheduledTransaction.recurrenceDay > 31 {
                return .invalidScheduleRule(index: index)
            }
            if let error = FinanceTransactionValidator.validate(
                scheduledTransaction.transactionTemplate,
                in: data,
                allowArchivedReferences: allowArchivedReferences
            ) {
                return .invalidScheduledTransaction(index: index, error: error)
            }
        }

        for (index, template) in data.templates.enumerated() {
            if let error = FinanceTransactionValidator.validate(
                template.transactionTemplate,
                in: data,
                allowArchivedReferences: allowArchivedReferences
            ) {
                return .invalidTemplate(index: index, error: error)
            }
        }

        for (index, budget) in data.budgets.enumerated() {
            guard data.categories.contains(where: { $0.id == budget.categoryID }),
                  budget.monthlyLimit.currency == budget.currency,
                  budget.monthlyLimit.minorUnits > 0 else {
                return .invalidBudget(index: index)
            }
        }

        for (index, rate) in data.exchangeRates.enumerated() {
            guard rate.baseCurrency != rate.quoteCurrency,
                  rate.quoteUnitsPerBaseUnit > 0 else {
                return .invalidExchangeRate(index: index)
            }
        }

        return nil
    }

    private static func hasDuplicateIDs(_ ids: [UUID]) -> Bool {
        Set(ids).count != ids.count
    }
}
