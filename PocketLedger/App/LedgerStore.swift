import Combine
import Foundation
import WidgetKit

enum FinanceAttentionDestination: Hashable {
    case uncategorizedTransactions
    case transferTransactions
    case scheduledTransactions
    case budgets
}

enum FinanceAttentionSeverity: Hashable {
    case notice
    case warning
}

struct FinanceAttentionItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let severity: FinanceAttentionSeverity
    let count: Int
    let destination: FinanceAttentionDestination
}

struct ScheduleRecordUndoReceipt {
    let transaction: LedgerTransaction
    let previousSchedule: ScheduledTransaction
    let recordedSchedule: ScheduledTransaction
}

func financeUndoScheduleRecord(
    _ receipt: ScheduleRecordUndoReceipt,
    in data: FinanceData
) -> FinanceData? {
    guard let scheduleIndex = data.scheduledTransactions.firstIndex(where: {
        $0.id == receipt.previousSchedule.id
    }), data.scheduledTransactions[scheduleIndex] == receipt.recordedSchedule,
          let transactionIndex = data.transactions.firstIndex(where: {
              $0.id == receipt.transaction.id
          }), data.transactions[transactionIndex] == receipt.transaction else {
        return nil
    }

    var restored = data
    restored.scheduledTransactions[scheduleIndex] = receipt.previousSchedule
    restored.transactions.remove(at: transactionIndex)
    return restored
}

@MainActor
final class LedgerStore: ObservableObject {
    private static let balanceAdjustmentCategoryID = UUID(
        uuidString: "6BFD8D43-EBD4-4B87-A024-A51032A440A1"
    )!

    @Published private(set) var data: FinanceData
    @Published private(set) var lastActionStatus: String?
    @Published private(set) var proAccessRequired: ProFeature?
    @Published private(set) var ledgerRevision = 0
    @Published private(set) var metalPriceFailures: Set<PreciousMetal> = []

    private let storage = FinanceStorage(context: "main-app")
    private let hasProAccess: () -> Bool
    private(set) var ledgerIndex: LedgerIndex

    init(hasProAccess: @escaping () -> Bool = { ProEntitlementStore.shared.hasProAccess }) {
        self.hasProAccess = hasProAccess
        var loadedData = storage.load()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DesignReviewMode") {
            let fixture = DesignReviewFixture.make()
            _ = storage.save(fixture, expected: loadedData, allowingCorruptedReplacement: true)
            loadedData = fixture
        }
        #endif
        data = loadedData
        ledgerIndex = LedgerIndex(data: loadedData)
        ledgerRevision = 1
    }

    var storageAvailable: Bool {
        storage.isPersistent && !storage.isCorrupted
    }

    var hasRecoverySnapshot: Bool {
        storage.hasRecoverySnapshot
    }

    var sharedStorageAvailable: Bool {
        storage.isAppGroupAvailable
    }

    var storageStatus: String {
        if storage.isCorrupted {
            return "Persistent database could not be decoded; restore or reset required"
        }
        if storage.isAppGroupAvailable {
            return "Persistent database is working"
        }
        if storage.isLocalFallback {
            return "Persistent local database is working; widget sharing is unavailable"
        }
        return "Persistent database unavailable"
    }

    var recentTransactions: [LedgerTransaction] {
        ledgerIndex.sortedTransactions
    }

    var attentionItems: [FinanceAttentionItem] {
        var items: [FinanceAttentionItem] = []
        var uncategorizedCount = 0
        var missingRateCount = 0

        for transaction in data.transactions {
            if transaction.kind == .expense,
               transaction.categoryID == nil,
               transactionHasIncludedAccount(transaction) {
                uncategorizedCount += 1
            }

            guard transaction.kind == .transfer, transaction.exchangeRate == nil else {
                continue
            }
            let currencies = Set((transaction.outflows + transaction.inflows).map { $0.money.currency })
            if currencies.count > 1 {
                missingRateCount += 1
            }
        }

        if uncategorizedCount > 0 {
            items.append(
                FinanceAttentionItem(
                    id: "uncategorized-expenses",
                    title: "Uncategorized expenses",
                    detail: "Assign categories so budgets and metrics stay accurate.",
                    systemImage: "tag",
                    severity: .notice,
                    count: uncategorizedCount,
                    destination: .uncategorizedTransactions
                )
            )
        }

        if missingRateCount > 0 {
            items.append(
                FinanceAttentionItem(
                    id: "missing-exchange-rates",
                    title: "Transfers need exchange rates",
                    detail: "Review cross-currency transfers before relying on their totals.",
                    systemImage: "arrow.left.arrow.right",
                    severity: .warning,
                    count: missingRateCount,
                    destination: .transferTransactions
                )
            )
        }

        let overduePausedCount = data.scheduledTransactions.filter { schedule in
            !schedule.isEnabled
                && schedule.nextRunDate <= .now
                && !(schedule.frequency == .once && schedule.lastRunDate != nil)
                && schedule.lastSkippedDate == nil
        }.count
        if overduePausedCount > 0 {
            items.append(
                FinanceAttentionItem(
                    id: "paused-scheduled-transactions",
                    title: "Paused scheduled entries",
                    detail: "Some recurring entries are past their next run date.",
                    systemImage: "pause.circle",
                    severity: .warning,
                    count: overduePausedCount,
                    destination: .scheduledTransactions
                )
            )
        }

        let overBudgetCount = data.budgets.filter { budget in
            budgetProjection(budget).minorUnits > budgetAllowance(budget).minorUnits
        }.count
        if overBudgetCount > 0 {
            items.append(
                FinanceAttentionItem(
                    id: "over-budget",
                    title: "Budgets need attention",
                    detail: "Review categories that are over limit or projected to exceed it.",
                    systemImage: "exclamationmark.triangle",
                    severity: .warning,
                    count: overBudgetCount,
                    destination: .budgets
                )
            )
        }

        return items.filter { !data.attentionState.dismissedIDs.contains($0.id) }
    }

    @discardableResult
    func dismissAttention(id: String) -> Bool {
        var updated = data
        updated.attentionState.dismissedIDs.insert(id)
        return persist(updated, successMessage: "Attention item dismissed")
    }

    @discardableResult
    func restoreDismissedAttention() -> Bool {
        guard !data.attentionState.dismissedIDs.isEmpty else { return true }
        var updated = data
        updated.attentionState.dismissedIDs.removeAll()
        return persist(updated, successMessage: "Dismissed attention items restored")
    }

    var rootCategories: [LedgerCategory] {
        ledgerIndex.rootCategories
    }

    var activeAccounts: [Account] {
        ledgerIndex.activeAccounts
    }

    private func denyForPro(_ status: String, feature: ProFeature) -> Bool {
        lastActionStatus = status
        proAccessRequired = feature
        ProEntitlementStore.shared.requestUpgrade(for: feature)
        return false
    }

    var activeCategories: [LedgerCategory] {
        ledgerIndex.activeCategories
    }

    var monthTransactionCount: Int {
        ledgerIndex.sortedTransactions.filter { transaction in
            transaction.date >= monthStart && transactionHasIncludedAccount(transaction)
        }.count
    }

    var topCategoryThisMonth: String? {
        var counts: [UUID: Int] = [:]
        for transaction in ledgerIndex.sortedTransactions where transaction.kind == .expense
            && transaction.date >= monthStart
            && ledgerIndex.categoryIncludedInTotals(transaction.categoryID)
            && transaction.outflows.contains(where: { includesInTotals(accountID: $0.accountID) }) {
            guard let categoryID = transaction.categoryID else { continue }
            counts[categoryID, default: 0] += 1
        }

        guard let categoryID = counts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        return categoryPath(for: categoryID)
    }

    @discardableResult
    func addTransaction(_ transaction: LedgerTransaction) -> Bool {
        guard validate(transaction) else { return false }
        var updated = data
        updated.transactions.append(transaction)
        return persist(updated, successMessage: "Transaction saved")
    }

    @discardableResult
    func updateTransaction(_ transaction: LedgerTransaction) -> Bool {
        guard let index = data.transactions.firstIndex(where: { $0.id == transaction.id }) else {
            lastActionStatus = "Transaction not found"
            return false
        }
        guard data.transactions[index].loanID == nil else {
            lastActionStatus = "Edit loan activity from the loan details."
            return false
        }

        guard validate(transaction, allowArchivedReferences: true) else { return false }

        var updated = data
        updated.transactions[index] = transaction
        return persist(updated, successMessage: "Transaction updated")
    }

    @discardableResult
    func deleteTransaction(id: UUID) -> Bool {
        guard !data.transactions.contains(where: { $0.id == id && $0.loanID != nil }) else {
            lastActionStatus = "Remove loan activity from the loan details."
            return false
        }
        var updated = data
        let originalCount = updated.transactions.count
        updated.transactions.removeAll { $0.id == id }
        guard updated.transactions.count != originalCount else {
            lastActionStatus = "Transaction not found"
            return false
        }
        return persist(updated, successMessage: "Transaction deleted")
    }

    @discardableResult
    func restoreTransaction(_ transaction: LedgerTransaction) -> Bool {
        guard !data.transactions.contains(where: { $0.id == transaction.id }) else {
            lastActionStatus = "Transaction is already in the ledger"
            return false
        }
        guard validate(transaction, allowArchivedReferences: true) else { return false }
        var updated = data
        updated.transactions.append(transaction)
        return persist(updated, successMessage: "Transaction restored")
    }

    @discardableResult
    func restoreTransactions(_ transactions: [LedgerTransaction]) -> Bool {
        let missing = transactions.filter { transaction in
            !data.transactions.contains(where: { $0.id == transaction.id })
        }
        guard !missing.isEmpty else {
            lastActionStatus = "Transactions are already in the ledger"
            return false
        }
        guard missing.allSatisfy({ validate($0, allowArchivedReferences: true) }) else {
            return false
        }
        var updated = data
        updated.transactions.append(contentsOf: missing)
        return persist(updated, successMessage: "Transactions restored")
    }

    @discardableResult
    func updateTransactionCategories(
        ids: Set<UUID>,
        categoryID: UUID?
    ) -> Bool {
        guard categoryID == nil || data.categories.contains(where: { $0.id == categoryID }) else {
            lastActionStatus = "Category not found"
            return false
        }

        var updated = data
        var changed = false
        for index in updated.transactions.indices where ids.contains(updated.transactions[index].id) {
            guard updated.transactions[index].loanID == nil else { continue }
            updated.transactions[index].categoryID = categoryID
            changed = true
        }
        guard changed else {
            lastActionStatus = "No transactions selected"
            return false
        }
        return persist(updated, successMessage: "Transaction categories updated")
    }

    @discardableResult
    func updateSingleAccountTransactions(
        ids: Set<UUID>,
        accountID: UUID
    ) -> Bool {
        guard let targetAccount = account(with: accountID) else {
            lastActionStatus = "Account not found"
            return false
        }

        var updated = data
        var changed = 0
        for index in updated.transactions.indices where ids.contains(updated.transactions[index].id) {
            var transaction = updated.transactions[index]
            guard transaction.loanID == nil else { continue }
            guard transaction.outflows.count + transaction.inflows.count == 1 else { continue }

            if let movementIndex = transaction.outflows.indices.first,
               transaction.outflows[movementIndex].money.currency == targetAccount.currency {
                transaction.outflows[movementIndex].accountID = accountID
            } else if let movementIndex = transaction.inflows.indices.first,
                      transaction.inflows[movementIndex].money.currency == targetAccount.currency {
                transaction.inflows[movementIndex].accountID = accountID
            } else {
                continue
            }

            guard FinanceTransactionValidator.validate(
                transaction,
                in: updated,
                allowArchivedReferences: true
            ) == nil else {
                continue
            }
            updated.transactions[index] = transaction
            changed += 1
        }

        guard changed > 0 else {
            lastActionStatus = "No selected single-account transactions matched that account"
            return false
        }
        return persist(updated, successMessage: "Transaction accounts updated")
    }

    @discardableResult
    func deleteTransactions(ids: Set<UUID>) -> Bool {
        var updated = data
        let originalCount = updated.transactions.count
        updated.transactions.removeAll { ids.contains($0.id) && $0.loanID == nil }
        guard updated.transactions.count != originalCount else {
            lastActionStatus = "No transactions selected"
            return false
        }
        return persist(
            updated,
            successMessage: "Deleted \(originalCount - updated.transactions.count) transactions"
        )
    }

    @discardableResult
    func duplicateTransaction(id: UUID) -> Bool {
        guard let transaction = data.transactions.first(where: { $0.id == id }) else {
            lastActionStatus = "Transaction not found"
            return false
        }
        guard transaction.loanID == nil else {
            lastActionStatus = "Duplicate loan activity from the loan details."
            return false
        }

        let duplicate = LedgerTransaction(
            note: transaction.note,
            kind: transaction.kind,
            categoryID: transaction.categoryID,
            amountDue: transaction.amountDue,
            outflows: transaction.outflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            inflows: transaction.inflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            exchangeRate: transaction.exchangeRate,
            changeAdjustment: transaction.changeAdjustment,
            attachmentIDs: transaction.attachmentIDs
        )
        guard validate(duplicate, allowArchivedReferences: true) else { return false }
        var updated = data
        updated.transactions.append(duplicate)
        return persist(updated, successMessage: "Transaction duplicated")
    }

    @discardableResult
    func addScheduledTransaction(_ scheduledTransaction: ScheduledTransaction) -> Bool {
        proAccessRequired = nil
        guard validate(scheduledTransaction.transactionTemplate) else { return false }
        if scheduledTransaction.isEnabled,
           !PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: scheduledTransaction.isEnabled,
            isAlreadyEnabled: false,
            enabledCount: data.scheduledTransactions.filter(\.isEnabled).count,
            hasPro: hasProAccess()
           ) {
            return denyForPro("Free includes up to ten enabled schedules.", feature: .schedules)
        }
        var updated = data
        updated.scheduledTransactions.append(scheduledTransaction)

        guard persist(updated, successMessage: "Transaction scheduled") else { return false }
        if scheduledTransaction.isEnabled,
           scheduledTransaction.nextRunDate <= .now {
            processDueScheduledTransactions()
        }
        return true
    }

    @discardableResult
    func updateScheduledTransaction(_ scheduledTransaction: ScheduledTransaction) -> Bool {
        proAccessRequired = nil
        guard let index = data.scheduledTransactions.firstIndex(where: { $0.id == scheduledTransaction.id }) else {
            lastActionStatus = "Scheduled transaction not found"
            return false
        }
        if scheduledTransaction.isEnabled,
           !PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: scheduledTransaction.isEnabled,
            isAlreadyEnabled: data.scheduledTransactions[index].isEnabled,
            enabledCount: data.scheduledTransactions.filter(\.isEnabled).count,
            hasPro: hasProAccess()
           ) {
            return denyForPro("Free includes up to ten enabled schedules.", feature: .schedules)
        }
        guard validate(scheduledTransaction.transactionTemplate, allowArchivedReferences: true) else { return false }

        var updated = data
        updated.scheduledTransactions[index] = scheduledTransaction
        guard persist(updated, successMessage: "Scheduled transaction updated") else { return false }

        if scheduledTransaction.isEnabled,
           scheduledTransaction.nextRunDate <= .now {
            processDueScheduledTransactions()
        }
        return true
    }

    @discardableResult
    func setScheduledTransactionEnabled(id: UUID, isEnabled: Bool) -> Bool {
        proAccessRequired = nil
        guard let index = data.scheduledTransactions.firstIndex(where: { $0.id == id }) else {
            lastActionStatus = "Scheduled transaction not found"
            return false
        }

        var scheduledTransaction = data.scheduledTransactions[index]
        guard !(isEnabled && scheduledTransaction.frequency == .once && scheduledTransaction.lastRunDate != nil) else {
            lastActionStatus = "Completed one-time transactions cannot be re-enabled"
            return false
        }
        if !PocketLedgerTierPolicy.canActivateSchedule(
            isEnabled: isEnabled,
            isAlreadyEnabled: scheduledTransaction.isEnabled,
            enabledCount: data.scheduledTransactions.filter(\.isEnabled).count,
            hasPro: hasProAccess()
        ) {
            return denyForPro("Free includes up to ten enabled schedules.", feature: .schedules)
        }
        scheduledTransaction.isEnabled = isEnabled
        var updated = data
        updated.scheduledTransactions[index] = scheduledTransaction
        let persisted = persist(
            updated,
            successMessage: isEnabled ? "Scheduled transaction enabled" : "Scheduled transaction paused"
        )
        if persisted, isEnabled, scheduledTransaction.nextRunDate <= .now {
            processDueScheduledTransactions()
        }
        return persisted
    }

    @discardableResult
    func skipNextScheduledTransaction(id: UUID) -> Bool {
        guard let index = data.scheduledTransactions.firstIndex(where: { $0.id == id }) else {
            lastActionStatus = "Scheduled transaction not found"
            return false
        }

        var schedule = data.scheduledTransactions[index]
        guard schedule.isEnabled else {
            lastActionStatus = "Enable the scheduled transaction before skipping it"
            return false
        }

        schedule.lastSkippedDate = .now
        if schedule.frequency == .once {
            schedule.isEnabled = false
        } else if let nextDate = schedule.frequency.nextDate(
            after: schedule.nextRunDate,
            calendar: .current,
            monthlyDay: schedule.recurrenceDay,
            monthlyRule: schedule.monthlyRule
        ) {
            schedule.nextRunDate = nextDate
        } else {
            schedule.isEnabled = false
        }

        var updated = data
        updated.scheduledTransactions[index] = schedule
        return persist(updated, successMessage: "Next scheduled entry skipped")
    }

    @discardableResult
    func recordScheduledTransactionNow(id: UUID, now: Date = .now) -> ScheduleRecordUndoReceipt? {
        guard let index = data.scheduledTransactions.firstIndex(where: { $0.id == id }) else {
            lastActionStatus = "Scheduled transaction not found"
            return nil
        }

        let previousSchedule = data.scheduledTransactions[index]
        var schedule = data.scheduledTransactions[index]
        guard schedule.isEnabled else {
            lastActionStatus = "Enable the scheduled transaction before recording it"
            return nil
        }

        let transaction = schedule.materializedTransaction(on: now)
        guard validate(transaction, allowArchivedReferences: true) else { return nil }

        var updated = data
        updated.transactions.append(transaction)
        schedule.lastRunDate = now
        schedule.lastSkippedDate = nil

        if schedule.frequency == .once {
            schedule.isEnabled = false
        } else {
            var nextDate = schedule.nextRunDate
            repeat {
                guard let candidate = schedule.frequency.nextDate(
                    after: nextDate,
                    calendar: .current,
                    monthlyDay: schedule.recurrenceDay,
                    monthlyRule: schedule.monthlyRule
                ),
                candidate > nextDate else {
                    schedule.isEnabled = false
                    break
                }
                nextDate = candidate
            } while nextDate <= now
            schedule.nextRunDate = nextDate
        }

        updated.scheduledTransactions[index] = schedule
        guard persist(updated, successMessage: "Scheduled transaction recorded") else { return nil }
        return ScheduleRecordUndoReceipt(
            transaction: transaction,
            previousSchedule: previousSchedule,
            recordedSchedule: schedule
        )
    }

    @discardableResult
    func undoScheduledTransactionRecord(_ receipt: ScheduleRecordUndoReceipt) -> Bool {
        guard let restored = financeUndoScheduleRecord(receipt, in: data) else {
            lastActionStatus = "Undo is unavailable because the schedule or transaction has changed."
            return false
        }
        return persist(restored, successMessage: "Scheduled transaction undone")
    }

    @discardableResult
    func deleteScheduledTransaction(id: UUID) -> Bool {
        var updated = data
        let originalCount = updated.scheduledTransactions.count
        updated.scheduledTransactions.removeAll { $0.id == id }
        guard updated.scheduledTransactions.count != originalCount else {
            lastActionStatus = "Scheduled transaction not found"
            return false
        }
        return persist(updated, successMessage: "Scheduled transaction deleted")
    }

    @discardableResult
    func processDueScheduledTransactions(now: Date = .now) -> Int {
        var updated = data
        var materializedCount = 0
        var changed = false
        let calendar = Calendar.current

        for index in updated.scheduledTransactions.indices {
            var scheduledTransaction = updated.scheduledTransactions[index]
            guard scheduledTransaction.isEnabled else { continue }

            var dueDate = scheduledTransaction.nextRunDate
            while scheduledTransaction.isEnabled && dueDate <= now {
                updated.transactions.append(scheduledTransaction.materializedTransaction(on: dueDate))
                materializedCount += 1
                changed = true
                scheduledTransaction.lastRunDate = dueDate
                scheduledTransaction.lastSkippedDate = nil

                guard scheduledTransaction.frequency != .once else {
                    scheduledTransaction.isEnabled = false
                    break
                }

                guard let nextDate = scheduledTransaction.frequency.nextDate(
                    after: dueDate,
                    calendar: calendar,
                    monthlyDay: scheduledTransaction.recurrenceDay,
                    monthlyRule: scheduledTransaction.monthlyRule
                ),
                      nextDate > dueDate else {
                    scheduledTransaction.isEnabled = false
                    break
                }

                scheduledTransaction.nextRunDate = nextDate
                dueDate = nextDate
            }

            updated.scheduledTransactions[index] = scheduledTransaction
        }

        guard changed else { return 0 }
        guard persist(
            updated,
            successMessage: "Added \(materializedCount) scheduled transaction\(materializedCount == 1 ? "" : "s")"
        ) else { return 0 }
        return materializedCount
    }

    var legacyLoanAccountsNeedingSetup: [Account] {
        data.accounts.filter { account in
            account.type == .loan
                && !data.loans.contains { $0.legacyAccountID == account.id }
                && !data.managedLegacyLoanAccountIDs.contains(account.id)
        }
    }

    func isManagedLegacyLoanAccount(_ accountID: UUID) -> Bool {
        data.managedLegacyLoanAccountIDs.contains(accountID)
            || data.loans.contains { $0.legacyAccountID == accountID }
    }

    func loan(with id: UUID) -> Loan? {
        ledgerIndex.loan(with: id)
    }

    @discardableResult
    func addLoanContact(name: String) -> LoanContact? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = data.loanContacts.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing
        }

        var updated = data
        let contact = LoanContact(name: name)
        updated.loanContacts.append(contact)
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The person or entity could not be saved."
            return nil
        }
        return persist(updated, successMessage: nil) ? contact : nil
    }

    @discardableResult
    func addLoan(_ loan: Loan, fundingTransaction: LedgerTransaction) -> Bool {
        guard !data.loans.contains(where: { $0.id == loan.id }),
              loan.legacyAccountID == nil,
              loan.startedAt <= .now,
              loan.fundingTransactionID == fundingTransaction.id,
              fundingTransaction.loanID == loan.id else {
            lastActionStatus = "The loan funding entry is invalid."
            return false
        }

        var updated = data
        updated.loans.append(loan)
        updated.transactions.append(fundingTransaction)
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The loan could not be saved. Check its amount and funding account."
            return false
        }
        return persist(updated, successMessage: "Loan added")
    }

    @discardableResult
    func updateLoan(_ loan: Loan) -> Bool {
        guard let index = data.loans.firstIndex(where: { $0.id == loan.id }) else {
            lastActionStatus = "Loan not found"
            return false
        }
        var updated = data
        updated.loans[index] = loan
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The loan could not be updated."
            return false
        }
        return persist(updated, successMessage: "Loan updated")
    }

    @discardableResult
    func recordLoanPayment(
        _ payment: LoanPayment,
        for loanID: UUID,
        transaction: LedgerTransaction
    ) -> Bool {
        guard let index = data.loans.firstIndex(where: { $0.id == loanID }) else {
            lastActionStatus = "Loan not found"
            return false
        }
        let loan = data.loans[index]
        guard !loan.isSettled,
              payment.amount.currency == loan.currency,
              payment.amount.minorUnits > 0,
              payment.amount.minorUnits <= loan.outstandingAmount.minorUnits,
              payment.date <= .now,
              payment.transactionID == transaction.id,
              transaction.loanID == loanID,
              transaction.loanPaymentID == payment.id,
              transaction.loanActivity == .payment,
              transaction.loanPrincipalAmount == payment.amount else {
            lastActionStatus = "Enter a payment no greater than the remaining loan balance."
            return false
        }

        var updated = data
        updated.loans[index].payments.append(payment)
        updated.transactions.append(transaction)
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The payment could not be saved. Check the account and exchange rate."
            return false
        }
        return persist(updated, successMessage: "Loan payment recorded")
    }

    @discardableResult
    func updateLoanPayment(
        _ payment: LoanPayment,
        for loanID: UUID,
        transaction: LedgerTransaction
    ) -> Bool {
        guard let loanIndex = data.loans.firstIndex(where: { $0.id == loanID }),
              let paymentIndex = data.loans[loanIndex].payments.firstIndex(where: { $0.id == payment.id }),
              let transactionIndex = data.transactions.firstIndex(where: { $0.id == payment.transactionID }),
              payment.transactionID == transaction.id,
              transaction.loanID == loanID,
              transaction.loanPaymentID == payment.id,
              transaction.loanActivity == .payment,
              transaction.loanPrincipalAmount == payment.amount else {
            lastActionStatus = "Loan payment not found"
            return false
        }

        let loan = data.loans[loanIndex]
        let availableToUpdate = loan.outstandingAmount.minorUnits
            + loan.payments[paymentIndex].amount.minorUnits
        guard payment.amount.currency == loan.currency,
              payment.amount.minorUnits > 0,
              payment.amount.minorUnits <= availableToUpdate,
              payment.date <= .now else {
            lastActionStatus = "Enter a payment no greater than the remaining loan balance."
            return false
        }

        var updated = data
        updated.loans[loanIndex].payments[paymentIndex] = payment
        updated.transactions[transactionIndex] = transaction
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The payment could not be updated. Check the account and exchange rate."
            return false
        }
        return persist(updated, successMessage: "Loan payment updated")
    }

    @discardableResult
    func deleteLoanPayment(loanID: UUID, paymentID: UUID) -> Bool {
        guard let loanIndex = data.loans.firstIndex(where: { $0.id == loanID }),
              let paymentIndex = data.loans[loanIndex].payments.firstIndex(where: { $0.id == paymentID }) else {
            lastActionStatus = "Loan payment not found"
            return false
        }
        let transactionID = data.loans[loanIndex].payments[paymentIndex].transactionID
        var updated = data
        updated.loans[loanIndex].payments.remove(at: paymentIndex)
        updated.transactions.removeAll { $0.id == transactionID }
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The loan payment could not be removed."
            return false
        }
        return persist(updated, successMessage: "Loan payment removed")
    }

    @discardableResult
    func convertLegacyLoanAccount(accountID: UUID, into loans: [Loan]) -> Bool {
        guard let accountIndex = data.accounts.firstIndex(where: { $0.id == accountID }),
              data.accounts[accountIndex].type == .loan,
              !isManagedLegacyLoanAccount(accountID) else {
            lastActionStatus = "Choose an existing loan account to convert."
            return false
        }
        let account = data.accounts[accountIndex]
        let currentBalance = balance(for: account)
        let startingTotal = loans.reduce(Int64.zero) { $0 + $1.startingAmount.minorUnits }
        let validZeroBalanceConversion = currentBalance.minorUnits == 0 && loans.isEmpty
        let validPositiveBalanceConversion = currentBalance.minorUnits > 0 && !loans.isEmpty
            && startingTotal == currentBalance.minorUnits
        guard currentBalance.minorUnits >= 0,
              loans.allSatisfy({ loan in
                  loan.currency == account.currency
                      && loan.startingAmount.currency == account.currency
                      && loan.startingAmount.minorUnits > 0
                      && loan.legacyAccountID == accountID
                      && loan.fundingTransactionID == nil
                      && loan.payments.isEmpty
              }),
              validZeroBalanceConversion || validPositiveBalanceConversion else {
            lastActionStatus = "Split the current balance across loans without changing its total."
            return false
        }

        var updated = data
        updated.accounts[accountIndex].includeInTotals = false
        updated.accounts[accountIndex].isArchived = true
        updated.managedLegacyLoanAccountIDs.insert(accountID)
        updated.loans.append(contentsOf: loans)
        guard FinanceDataValidator.validate(updated) == nil else {
            lastActionStatus = "The existing loan account could not be converted."
            return false
        }
        return persist(updated, successMessage: "Existing loan account converted")
    }

    @discardableResult
    func addAccount(_ account: Account) -> Bool {
        proAccessRequired = nil
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastActionStatus = "Enter an account name"
            return false
        }
        guard PocketLedgerTierPolicy.canCreateAccount(
            type: account.type,
            activeCount: data.accounts.filter { !$0.isArchived }.count,
            hasPro: hasProAccess()
        ) else {
            let feature: ProFeature = PocketLedgerTierPolicy.accountTypeRequiresPro(account.type)
                ? .accountTypes : .accounts
            return denyForPro(
                feature == .accountTypes
                    ? "Pro unlocks investment and physical-asset accounts."
                    : "Free includes up to five active accounts.",
                feature: feature
            )
        }
        var updated = data
        updated.accounts.append(account)
        return persist(updated, successMessage: "Account added")
    }

    @discardableResult
    func updateAccount(_ account: Account) -> Bool {
        proAccessRequired = nil
        guard let index = data.accounts.firstIndex(where: { $0.id == account.id }) else {
            lastActionStatus = "Account not found"
            return false
        }
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastActionStatus = "Enter an account name"
            return false
        }
        let original = data.accounts[index]
        if original.tracking?.hasHistory == true,
           account.type != original.type || account.currency != original.currency {
            lastActionStatus = "An account with asset history must keep its original type and currency."
            return false
        }
        if account.type != original.type,
           PocketLedgerTierPolicy.accountTypeRequiresPro(account.type),
           !hasProAccess() {
            return denyForPro(
                "Pro unlocks investment and physical-asset accounts.",
                feature: .accountTypes
            )
        }
        if original.isArchived, !account.isArchived,
           PocketLedgerTierPolicy.accountTypeRequiresPro(account.type),
           !hasProAccess() {
            return denyForPro(
                "Pro unlocks investment and physical-asset accounts.",
                feature: .accountTypes
            )
        }
        if original.isArchived, !account.isArchived,
           !hasProAccess(),
           data.accounts.filter({ !$0.isArchived }).count >= PocketLedgerTierPolicy.freeAccountLimit {
            return denyForPro("Free includes up to five active accounts.", feature: .accounts)
        }
        var accountToSave = account
        if isManagedLegacyLoanAccount(account.id) {
            guard account.type == .loan,
                  account.currency == original.currency,
                  account.openingBalance == original.openingBalance else {
                lastActionStatus = "A converted loan account can only change its name."
                return false
            }
            accountToSave.includeInTotals = false
            accountToSave.isArchived = true
        }

        var updated = original.currency == accountToSave.currency
            ? data
            : FinanceAccountCurrencyMigration.migrating(
                data,
                accountID: account.id,
                from: original.currency,
                to: accountToSave.currency
            )
        updated.accounts[index] = accountToSave
        return persist(updated, successMessage: "Account updated")
    }

    @discardableResult
    func deleteAccount(id: UUID) -> Bool {
        guard data.accounts.contains(where: { $0.id == id }) else {
            lastActionStatus = "Account not found"
            return false
        }

        let directlyLinkedTransactions = data.transactions.filter { transaction in
            (transaction.outflows + transaction.inflows).contains { $0.accountID == id }
        }
        var affectedLoanIDs = Set(data.loans.filter {
            $0.settlementAccountID == id || $0.legacyAccountID == id
        }.map(\.id))
        affectedLoanIDs.formUnion(directlyLinkedTransactions.compactMap(\.loanID))

        let deletedTransactions = data.transactions.filter { transaction in
            transaction.loanID.map(affectedLoanIDs.contains) == true
                || (transaction.outflows + transaction.inflows).contains { $0.accountID == id }
        }
        let deletedTransactionIDs = Set(deletedTransactions.map(\.id))
        let retainedTransactions = data.transactions.filter { !deletedTransactionIDs.contains($0.id) }
        let candidateAttachmentIDs = Set(deletedTransactions.flatMap(\.attachmentIDs))
        let orphanedAttachments = data.attachments.filter { attachment in
            candidateAttachmentIDs.contains(attachment.id)
                && !retainedTransactions.contains { $0.attachmentIDs.contains(attachment.id) }
        }

        var updated = data
        updated.accounts.removeAll { $0.id == id }
        updated.transactions.removeAll { deletedTransactionIDs.contains($0.id) }
        updated.loans.removeAll { affectedLoanIDs.contains($0.id) }
        updated.managedLegacyLoanAccountIDs.remove(id)
        updated.scheduledTransactions.removeAll { schedule in
            (schedule.outflows + schedule.inflows).contains { $0.accountID == id }
        }
        updated.templates.removeAll { template in
            (template.outflows + template.inflows).contains { $0.accountID == id }
        }
        updated.attachments.removeAll { attachment in
            orphanedAttachments.contains(where: { $0.id == attachment.id })
        }
        updated.reconciliations.removeValue(forKey: id)

        if let validationError = FinanceDataValidator.validate(updated) {
            lastActionStatus = "Account was not deleted: \(validationError.localizedDescription)"
            return false
        }
        guard persist(updated, successMessage: "Account and related history deleted") else {
            return false
        }
        for attachment in orphanedAttachments {
            storage.deleteAttachment(relativePath: attachment.relativePath)
        }
        return true
    }

    @discardableResult
    func setAccountArchived(accountID: UUID, isArchived: Bool) -> Bool {
        proAccessRequired = nil
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID }) else {
            lastActionStatus = "Account not found"
            return false
        }
        if isManagedLegacyLoanAccount(accountID), !isArchived {
            lastActionStatus = "This archived account is retained as the history for managed loans."
            return false
        }
        if !isArchived,
           PocketLedgerTierPolicy.accountTypeRequiresPro(data.accounts[index].type),
           !hasProAccess() {
            return denyForPro(
                "Pro unlocks investment and physical-asset accounts.",
                feature: .accountTypes
            )
        }
        if !isArchived,
           !hasProAccess(),
           data.accounts.filter({ !$0.isArchived }).count >= PocketLedgerTierPolicy.freeAccountLimit {
            return denyForPro("Free includes up to five active accounts.", feature: .accounts)
        }
        var updated = data
        updated.accounts[index].isArchived = isArchived
        return persist(
            updated,
            successMessage: isArchived ? "Account archived" : "Account restored"
        )
    }

    @discardableResult
    func moveAccount(accountID: UUID, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
              let sourceIndex = data.accounts.firstIndex(where: { $0.id == accountID }),
              !data.accounts[sourceIndex].isArchived else {
            return false
        }

        let accountType = data.accounts[sourceIndex].type
        let typeIndices = data.accounts.indices.filter { index in
            let account = data.accounts[index]
            return !account.isArchived && account.type == accountType
        }
        guard let position = typeIndices.firstIndex(of: sourceIndex) else { return false }
        let targetPosition = position + offset
        guard typeIndices.indices.contains(targetPosition) else { return false }

        var updated = data
        updated.accounts.swapAt(sourceIndex, typeIndices[targetPosition])
        return persist(updated, successMessage: "Account order updated")
    }

    @discardableResult
    func moveAccount(accountID: UUID, beforeAccountID: UUID) -> Bool {
        guard accountID != beforeAccountID,
              let sourceIndex = data.accounts.firstIndex(where: { $0.id == accountID }),
              let targetIndex = data.accounts.firstIndex(where: { $0.id == beforeAccountID }),
              !data.accounts[sourceIndex].isArchived,
              !data.accounts[targetIndex].isArchived,
              data.accounts[sourceIndex].type == data.accounts[targetIndex].type else {
            return false
        }

        let sectionIndices = data.accounts.indices.filter { index in
            let account = data.accounts[index]
            return !account.isArchived && account.type == data.accounts[sourceIndex].type
        }
        var sectionAccounts = sectionIndices.map { data.accounts[$0] }
        guard let sourcePosition = sectionAccounts.firstIndex(where: { $0.id == accountID }) else {
            return false
        }
        let movingAccount = sectionAccounts.remove(at: sourcePosition)
        guard let targetPosition = sectionAccounts.firstIndex(where: { $0.id == beforeAccountID }) else {
            return false
        }
        sectionAccounts.insert(movingAccount, at: targetPosition)

        var updated = data
        for (index, account) in zip(sectionIndices, sectionAccounts) {
            updated.accounts[index] = account
        }
        return persist(updated, successMessage: "Account order updated")
    }

    @discardableResult
    func setAccountIncludedInTotals(accountID: UUID, included: Bool) -> Bool {
        guard let accountIndex = data.accounts.firstIndex(where: { $0.id == accountID }) else {
            lastActionStatus = "Account not found"
            return false
        }
        if isManagedLegacyLoanAccount(accountID), included {
            lastActionStatus = "This balance is represented by managed loans."
            return false
        }

        var updated = data
        updated.accounts[accountIndex].includeInTotals = included
        return persist(
            updated,
            successMessage: included ? "Account included in totals" : "Account excluded from totals"
        )
    }

    @discardableResult
    func addCategory(_ category: LedgerCategory) -> Bool {
        guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastActionStatus = "Enter a category name"
            return false
        }
        guard category.parentID == nil || data.categories.contains(where: { $0.id == category.parentID }) else {
            lastActionStatus = "Choose an existing parent category"
            return false
        }
        var updated = data
        updated.categories.append(category)
        return persist(updated, successMessage: "Category added")
    }

    @discardableResult
    func updateCategory(_ category: LedgerCategory) -> Bool {
        guard let index = data.categories.firstIndex(where: { $0.id == category.id }) else {
            lastActionStatus = "Category not found"
            return false
        }
        guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastActionStatus = "Enter a category name"
            return false
        }
        guard category.parentID != category.id,
              category.parentID == nil || data.categories.contains(where: { $0.id == category.parentID }) else {
            lastActionStatus = "Choose a valid parent category"
            return false
        }
        guard !wouldCreateCategoryCycle(category) else {
            lastActionStatus = "A category cannot be its own ancestor"
            return false
        }

        var updated = data
        updated.categories[index] = category
        return persist(updated, successMessage: "Category updated")
    }

    @discardableResult
    func setCategoryArchived(categoryID: UUID, isArchived: Bool) -> Bool {
        guard let index = data.categories.firstIndex(where: { $0.id == categoryID }) else {
            lastActionStatus = "Category not found"
            return false
        }
        var updated = data
        updated.categories[index].isArchived = isArchived
        return persist(
            updated,
            successMessage: isArchived ? "Category archived" : "Category restored"
        )
    }

    @discardableResult
    func upsertBudget(_ budget: LedgerBudget) -> Bool {
        proAccessRequired = nil
        guard budget.monthlyLimit.minorUnits > 0,
              data.categories.contains(where: { $0.id == budget.categoryID }),
              budget.monthlyLimit.currency == budget.currency else {
            lastActionStatus = "Enter a valid budget"
            return false
        }

        let existing = data.budgets.first(where: { $0.id == budget.id })
        if existing == nil,
           !PocketLedgerTierPolicy.canCreateBudget(count: data.budgets.count, hasPro: hasProAccess()) {
            return denyForPro("Free includes up to five budgets.", feature: .budgets)
        }
        if budget.rollover,
           !PocketLedgerTierPolicy.canUseRollover(
            isAlreadyEnabled: existing?.rollover == true,
            hasPro: hasProAccess()
           ) {
            return denyForPro("Budget rollover is included with Pro.", feature: .budgetRollover)
        }

        var updated = data
        if let index = updated.budgets.firstIndex(where: { $0.id == budget.id }) {
            updated.budgets[index] = budget
        } else {
            updated.budgets.append(budget)
        }
        return persist(updated, successMessage: "Budget saved")
    }

    @discardableResult
    func deleteBudget(id: UUID) -> Bool {
        var updated = data
        let originalCount = updated.budgets.count
        updated.budgets.removeAll { $0.id == id }
        guard updated.budgets.count != originalCount else {
            lastActionStatus = "Budget not found"
            return false
        }
        return persist(updated, successMessage: "Budget deleted")
    }

    @discardableResult
    func upsertSavingsGoal(_ goal: SavingsGoal) -> Bool {
        var goal = goal
        goal.name = goal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.name.isEmpty,
              goal.targetAmount.minorUnits > 0,
              goal.currentAmount.minorUnits >= 0,
              goal.targetAmount.currency == goal.currentAmount.currency else {
            lastActionStatus = "Enter a name, a positive target, and a valid saved amount."
            return false
        }

        var updated = data
        if let index = updated.savingsGoals.firstIndex(where: { $0.id == goal.id }) {
            updated.savingsGoals[index] = goal
        } else {
            updated.savingsGoals.append(goal)
        }
        return persist(updated, successMessage: "Savings goal saved")
    }

    @discardableResult
    func deleteSavingsGoal(id: UUID) -> Bool {
        var updated = data
        let originalCount = updated.savingsGoals.count
        updated.savingsGoals.removeAll { $0.id == id }
        guard updated.savingsGoals.count != originalCount else {
            lastActionStatus = "Savings goal not found"
            return false
        }
        return persist(updated, successMessage: "Savings goal deleted")
    }

    @discardableResult
    func addTemplate(_ template: LedgerTemplate) -> Bool {
        var updated = data
        updated.templates.append(template)
        return persist(updated, successMessage: "Template saved")
    }

    @discardableResult
    func updateTemplate(_ template: LedgerTemplate) -> Bool {
        guard let index = data.templates.firstIndex(where: { $0.id == template.id }) else {
            lastActionStatus = "Template not found"
            return false
        }
        var template = template
        template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.name.isEmpty else {
            lastActionStatus = "Enter a name for this template"
            return false
        }
        guard validate(template.transactionTemplate, allowArchivedReferences: true) else { return false }
        var updated = data
        updated.templates[index] = template
        return persist(updated, successMessage: "Template updated")
    }

    @discardableResult
    func deleteTemplate(id: UUID) -> Bool {
        var updated = data
        let originalCount = updated.templates.count
        updated.templates.removeAll { $0.id == id }
        guard updated.templates.count != originalCount else {
            lastActionStatus = "Template not found"
            return false
        }
        return persist(updated, successMessage: "Template deleted")
    }

    func budgetSpent(_ budget: LedgerBudget, in interval: DateInterval? = nil) -> Money {
        financeBudgetSpent(budget, in: data, interval: interval, using: ledgerIndex)
    }

    func budgetAllowance(_ budget: LedgerBudget, for interval: DateInterval? = nil) -> Money {
        financeBudgetAllowance(budget, in: data, interval: interval, using: ledgerIndex)
    }

    func budgetProjection(_ budget: LedgerBudget, on date: Date = .now) -> Money {
        let spent = budgetSpent(budget)
        let calendar = Calendar.current
        let dayCount = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        let elapsedDay = calendar.component(.day, from: date)
        let progress = min(
            max(Double(elapsedDay) / Double(max(dayCount, 1)), 0.01),
            1
        )
        return Money(
            currency: budget.currency,
            minorUnits: Int64((Double(spent.minorUnits) / progress).rounded())
        )
    }

    func exchangeRate(base: LedgerCurrency, quote: LedgerCurrency) -> ExchangeRate? {
        guard base != quote else { return nil }

        if let exact = data.exchangeRates.first(where: {
            $0.baseCurrency == base && $0.quoteCurrency == quote
        }) {
            return exact
        }

        guard let reverse = data.exchangeRates.first(where: {
            $0.baseCurrency == quote && $0.quoteCurrency == base
        }), reverse.quoteUnitsPerBaseUnit > 0 else {
            return nil
        }

        return ExchangeRate(
            baseCurrency: base,
            quoteCurrency: quote,
            quoteUnitsPerBaseUnit: Decimal(1) / reverse.quoteUnitsPerBaseUnit
        )
    }

    @discardableResult
    func upsertExchangeRate(_ exchangeRate: ExchangeRate) -> Bool {
        guard exchangeRate.baseCurrency != exchangeRate.quoteCurrency,
              exchangeRate.quoteUnitsPerBaseUnit > 0 else {
            lastActionStatus = "Enter a positive rate between two different currencies"
            return false
        }

        var updated = data
        updated.exchangeRates.removeAll {
            Set([
                $0.baseCurrency,
                $0.quoteCurrency
            ]) == Set([
                exchangeRate.baseCurrency,
                exchangeRate.quoteCurrency
            ])
        }
        updated.exchangeRates.append(exchangeRate)
        return persist(updated, successMessage: "Exchange rate saved")
    }

    @discardableResult
    func deleteExchangeRate(_ exchangeRate: ExchangeRate) -> Bool {
        var updated = data
        let originalCount = updated.exchangeRates.count
        updated.exchangeRates.removeAll { $0.id == exchangeRate.id }
        guard updated.exchangeRates.count != originalCount else {
            lastActionStatus = "Exchange rate not found"
            return false
        }
        return persist(updated, successMessage: "Exchange rate deleted")
    }

    @discardableResult
    func resetLedger() -> Bool {
        if !storage.isCorrupted,
           !storage.writeRecoverySnapshot(data) {
            lastActionStatus = "Reset was not started because the last-good recovery snapshot could not be saved."
            return false
        }
        let saved = persist(.empty, successMessage: "Ledger reset", allowingCorruptedReplacement: true)
        if saved { storage.deleteAllAttachments() }
        return saved
    }

    @discardableResult
    func deleteRecoverySnapshot() -> Bool {
        guard storage.deleteRecoverySnapshot() else {
            lastActionStatus = "The recovery snapshot could not be deleted."
            return false
        }
        lastActionStatus = "Recovery snapshot deleted"
        return true
    }

    @discardableResult
    func replaceData(
        _ imported: FinanceData,
        attachmentFiles: [UUID: Data] = [:],
        preservingRecoverySnapshot: Bool = false
    ) -> Bool {
        let prepared = materializeAttachments(in: imported, files: attachmentFiles)
        guard validateImportedData(prepared) else { return false }
        if !preservingRecoverySnapshot,
           !storage.isCorrupted,
           !storage.writeRecoverySnapshot(data) {
            lastActionStatus = "Restore was not started because the last-good recovery snapshot could not be saved."
            return false
        }
        let oldPaths = Set(data.attachments.map(\.relativePath))
        guard persist(prepared, successMessage: "Ledger restored", allowingCorruptedReplacement: true) else {
            return false
        }
        for path in oldPaths {
            storage.deleteAttachment(relativePath: path)
        }
        return true
    }

    @discardableResult
    func restoreLastGoodSnapshot() -> Bool {
        guard let snapshot = storage.loadRecoverySnapshot() else {
            lastActionStatus = "No last-good recovery snapshot is available."
            return false
        }
        return replaceData(
            snapshot.data,
            attachmentFiles: snapshot.attachmentData,
            preservingRecoverySnapshot: true
        )
    }

    @discardableResult
    func mergeData(_ imported: FinanceData, attachmentFiles: [UUID: Data] = [:]) -> Bool {
        let imported = materializeAttachments(in: imported, files: attachmentFiles)
        var updated = data
        let accountIDs = Set(updated.accounts.map(\.id))
        let categoryIDs = Set(updated.categories.map(\.id))
        let transactionIDs = Set(updated.transactions.map(\.id))
        let scheduledTransactionIDs = Set(updated.scheduledTransactions.map(\.id))
        let budgetIDs = Set(updated.budgets.map(\.id))
        let savingsGoalIDs = Set(updated.savingsGoals.map(\.id))
        let templateIDs = Set(updated.templates.map(\.id))
        let attachmentIDs = Set(updated.attachments.map(\.id))
        let loanIDs = Set(updated.loans.map(\.id))
        let contactIDs = Set(updated.loanContacts.map(\.id))

        for account in imported.accounts {
            guard let tracking = account.tracking,
                  let index = updated.accounts.firstIndex(where: { $0.id == account.id }) else { continue }
            guard updated.accounts[index].type == account.type,
                  updated.accounts[index].currency == account.currency else {
                lastActionStatus = "Tracked account \"\(account.name)\" has a different type or currency. Use Replace to restore this backup exactly."
                return false
            }
            if updated.accounts[index].tracking == nil {
                updated.accounts[index].tracking = tracking
            } else {
                updated.accounts[index].tracking?.merge(tracking)
            }
        }
        for quote in imported.metalQuotes {
            if let index = updated.metalQuotes.firstIndex(where: { $0.metal == quote.metal }) {
                if quote.fetchedAt > updated.metalQuotes[index].fetchedAt {
                    updated.metalQuotes[index] = quote
                }
            } else {
                updated.metalQuotes.append(quote)
            }
        }
        updated.accounts.append(contentsOf: imported.accounts.filter { !accountIDs.contains($0.id) })
        updated.loans.append(contentsOf: imported.loans.filter { !loanIDs.contains($0.id) })
        updated.loanContacts.append(contentsOf: imported.loanContacts.filter { !contactIDs.contains($0.id) })
        updated.managedLegacyLoanAccountIDs.formUnion(imported.managedLegacyLoanAccountIDs)
        updated.categories.append(contentsOf: imported.categories.filter { !categoryIDs.contains($0.id) })
        updated.transactions.append(contentsOf: imported.transactions.filter { !transactionIDs.contains($0.id) })
        updated.scheduledTransactions.append(
            contentsOf: imported.scheduledTransactions.filter { !scheduledTransactionIDs.contains($0.id) }
        )
        updated.budgets.append(contentsOf: imported.budgets.filter { !budgetIDs.contains($0.id) })
        updated.savingsGoals.append(contentsOf: imported.savingsGoals.filter { !savingsGoalIDs.contains($0.id) })
        updated.templates.append(contentsOf: imported.templates.filter { !templateIDs.contains($0.id) })
        updated.attachments.append(contentsOf: imported.attachments.filter { !attachmentIDs.contains($0.id) })
        for rate in imported.exchangeRates {
            updated.exchangeRates.removeAll {
                Set([$0.baseCurrency, $0.quoteCurrency]) == Set([rate.baseCurrency, rate.quoteCurrency])
            }
            updated.exchangeRates.append(rate)
        }

        guard validateImportedData(updated) else { return false }
        return persist(updated, successMessage: "Import completed", allowingAssetActivity: true)
    }

    @discardableResult
    func addAttachment(
        data attachmentData: Data,
        fileName: String,
        contentType: String,
        receiptItems: [LedgerReceiptLineItem] = [],
        extractedTotal: Money? = nil
    ) -> LedgerAttachment? {
        do {
            let relativePath = try storage.storeAttachment(
                attachmentData,
                fileExtension: URL(fileURLWithPath: fileName).pathExtension
            )
            let attachment = LedgerAttachment(
                fileName: fileName,
                contentType: contentType,
                relativePath: relativePath,
                receiptItems: receiptItems,
                extractedTotal: extractedTotal
            )
            var updated = data
            updated.attachments.append(attachment)
            guard persist(updated, successMessage: "Attachment saved") else {
                storage.deleteAttachment(relativePath: relativePath)
                return nil
            }
            return attachment
        } catch {
            lastActionStatus = "Attachment could not be saved"
            return nil
        }
    }

    func attachmentData(for attachmentID: UUID) -> Data? {
        guard let attachment = data.attachments.first(where: { $0.id == attachmentID }) else {
            return nil
        }
        return storage.attachmentData(relativePath: attachment.relativePath)
    }

    func attachmentURL(for attachmentID: UUID) -> URL? {
        guard let attachment = data.attachments.first(where: { $0.id == attachmentID }) else {
            return nil
        }
        return storage.attachmentURL(relativePath: attachment.relativePath)
    }

    func attachmentFiles() -> [UUID: Data] {
        data.attachments.reduce(into: [UUID: Data]()) { files, attachment in
            guard let data = attachmentData(for: attachment.id) else { return }
            files[attachment.id] = data
        }
    }

    @discardableResult
    func deleteAttachment(id: UUID) -> Bool {
        guard let attachment = data.attachments.first(where: { $0.id == id }) else {
            lastActionStatus = "Attachment not found"
            return false
        }
        var updated = data
        updated.attachments.removeAll { $0.id == id }
        updated.transactions = updated.transactions.map { transaction in
            var transaction = transaction
            transaction.attachmentIDs.removeAll { $0 == id }
            return transaction
        }
        guard persist(updated, successMessage: "Attachment deleted") else { return false }
        storage.deleteAttachment(relativePath: attachment.relativePath)
        return true
    }

    @discardableResult
    func replaceAttachment(
        id: UUID,
        data attachmentData: Data,
        fileName: String,
        contentType: String
    ) -> Bool {
        guard let index = data.attachments.firstIndex(where: { $0.id == id }) else {
            lastActionStatus = "Attachment not found"
            return false
        }

        do {
            let oldPath = data.attachments[index].relativePath
            let newPath = try storage.storeAttachment(
                attachmentData,
                fileExtension: URL(fileURLWithPath: fileName).pathExtension
            )
            var updated = data
            updated.attachments[index].fileName = fileName
            updated.attachments[index].contentType = contentType
            updated.attachments[index].relativePath = newPath
            guard persist(updated, successMessage: "Attachment replaced") else {
                storage.deleteAttachment(relativePath: newPath)
                return false
            }
            storage.deleteAttachment(relativePath: oldPath)
            return true
        } catch {
            lastActionStatus = "Attachment could not be replaced"
            return false
        }
    }

    private func materializeAttachments(in imported: FinanceData, files: [UUID: Data]) -> FinanceData {
        var prepared = imported
        for index in prepared.attachments.indices {
            let attachment = prepared.attachments[index]
            if let file = files[attachment.id],
               let relativePath = try? storage.storeAttachment(
                   file,
                   fileExtension: URL(fileURLWithPath: attachment.fileName).pathExtension
               ) {
                prepared.attachments[index].relativePath = relativePath
            } else {
                prepared.attachments[index].relativePath = "missing-\(attachment.id.uuidString)"
            }
        }
        return prepared
    }

    func reload() {
        replaceData(storage.load())
    }

    func account(with id: UUID) -> Account? {
        ledgerIndex.account(with: id)
    }

    func includesInTotals(accountID: UUID) -> Bool {
        ledgerIndex.includesInTotals(accountID: accountID)
    }

    func transactionHasIncludedAccount(_ transaction: LedgerTransaction) -> Bool {
        (transaction.outflows + transaction.inflows).contains {
            includesInTotals(accountID: $0.accountID)
        }
    }

    func balance(for account: Account) -> Money {
        ledgerIndex.balance(for: account)
    }

    func valuation(for account: Account) -> Money { ledgerIndex.valuation(for: account) }

    func gainLoss(for account: Account) -> Money? {
        FinanceAssetTracking.gainLoss(account: account, recordedBalance: balance(for: account), data: data)
    }

    func captureDailyPhysicalAssetGainHistory() {
        _ = persist(data, successMessage: nil, allowingAssetActivity: true)
    }

    func metalPricePerGram(account: Account, metal: PreciousMetal) -> Decimal? {
        FinanceAssetTracking.pricePerGram(account: account, metal: metal, data: data)
    }

    func metalValuation(account: Account, purchase: MetalPurchase) -> Money? {
        guard let price = metalPricePerGram(account: account, metal: purchase.metal) else { return nil }
        return try? FinanceAssetTracking.money(purchase.pureWeightGrams * price, currency: account.currency)
    }

    func metalQuoteDescription(account: Account, metal: PreciousMetal) -> String {
        let setting = account.tracking?.metalPricing.first { $0.metal == metal }
        guard setting?.isAutomaticEnabled == true else {
            if setting?.mode == .automatic {
                return "Price needed · opt in to Automatic or enter a manual price"
            }
            return "Manual · \(setting?.asOf?.formatted(date: .abbreviated, time: .shortened) ?? "Price needed")"
        }
        guard let quote = data.metalQuotes.first(where: { $0.metal == metal }) else { return "Price needed · enter a manual price or refresh" }
        let stale = metalPriceFailures.contains(metal) || Date.now.timeIntervalSince(quote.marketDate) > 900
        let conversion = account.currency != .usd && metalPricePerGram(account: account, metal: metal) == nil
            ? " · Exchange rate needed; enter a manual price" : ""
        return "Gold API\(stale ? " · Stale" : "") · \(quote.marketDate.formatted(date: .abbreviated, time: .shortened))\(conversion)"
    }

    func refreshMetalPrices(force: Bool = false) async {
        let metals = Set(data.accounts.filter { !$0.isArchived && $0.type == .physicalAsset }.flatMap { account in
            let selectedMetal = account.tracking?.physicalAssetSubtype?.metal.map { [$0] } ?? []
            let heldMetals = (account.tracking?.metalPurchases ?? [])
                .filter { $0.remainingWeightGrams > 0 }
                .map(\.metal)
            return (selectedMetal + heldMetals).filter { metal in
                account.tracking?.metalPricing.first(where: { $0.metal == metal })?.isAutomaticEnabled == true
            }
        })
        for metal in metals {
            do {
                let quote = try await MetalPriceService.shared.fetch(metal: metal, cached: data.metalQuotes.first { $0.metal == metal }, force: force)
                var updated = data
                updated.metalQuotes.removeAll { $0.metal == metal }
                updated.metalQuotes.append(quote)
                if persist(updated, successMessage: "Metal prices updated") { metalPriceFailures.remove(metal) }
                else { metalPriceFailures.insert(metal) }
            } catch {
                metalPriceFailures.insert(metal)
                lastActionStatus = "Price refresh failed. Last saved quotes remain available; you can enter a manual price."
            }
        }
    }

    @discardableResult
    private func saveAssetActivity(_ change: () throws -> FinanceData, message: String) -> Bool {
        do { return persist(try change(), successMessage: message, allowingAssetActivity: true) }
        catch { lastActionStatus = error.localizedDescription; return false }
    }

    @discardableResult
    func addMetalPurchase(accountID: UUID, purchase: MetalPurchase, fundingAccountID: UUID?, reconcileOpeningBalance: Bool) -> Bool {
        saveAssetActivity({ try FinanceAssetTracking.addPurchase(in: data, accountID: accountID, purchase: purchase, fundingAccountID: fundingAccountID, reconcileOpeningBalance: reconcileOpeningBalance) }, message: "Metal purchase saved")
    }

    @discardableResult
    func sellMetal(accountID: UUID, purchaseID: UUID, weightGrams: Decimal, proceeds: Money, date: Date, destinationAccountID: UUID) -> Bool {
        saveAssetActivity({ try FinanceAssetTracking.sell(in: data, accountID: accountID, purchaseID: purchaseID, weightGrams: weightGrams, proceeds: proceeds, date: date, destinationAccountID: destinationAccountID) }, message: "Metal sale saved")
    }

    @discardableResult
    func sellOtherAsset(accountID: UUID, sharePercent: Decimal, proceeds: Money, date: Date, destinationAccountID: UUID) -> Bool {
        saveAssetActivity({ try FinanceAssetTracking.sellOtherAsset(in: data, accountID: accountID, sharePercent: sharePercent, proceeds: proceeds, date: date, destinationAccountID: destinationAccountID) }, message: "Asset sale saved")
    }

    @discardableResult
    func updateInvestmentValuation(accountID: UUID, amount: Money, date: Date, confirmRecordedBalance: Bool) -> Bool {
        saveAssetActivity({ try FinanceAssetTracking.updateInvestment(in: data, accountID: accountID, amount: amount, date: date, confirmRecordedBalance: confirmRecordedBalance) }, message: "Investment valuation updated")
    }

    @discardableResult
    func realizeInvestment(accountID: UUID, amount: Money, date: Date) -> Bool {
        saveAssetActivity({ try FinanceAssetTracking.realizeInvestment(in: data, accountID: accountID, amount: amount, date: date) }, message: "Investment gain or loss realized")
    }

    @discardableResult
    func undoLatestAssetActivity(accountID: UUID) -> Bool {
        saveAssetActivity({ try FinanceAssetTracking.undoLatest(in: data, accountID: accountID) }, message: "Latest tracking entry undone")
    }

    @discardableResult
    func disableAssetTracking(accountID: UUID) -> Bool {
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID }), data.accounts[index].tracking?.hasHistory != true else {
            lastActionStatus = "Undo tracking history before disabling tracking."
            return false
        }
        var updated = data
        updated.accounts[index].tracking = nil
        return persist(updated, successMessage: "Tracking disabled", allowingAssetActivity: true)
    }

    @discardableResult
    func setMetalPricing(accountID: UUID, setting: MetalPriceSetting) -> Bool {
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID && $0.type == .physicalAsset && !$0.isArchived }), data.accounts[index].tracking != nil else {
            lastActionStatus = "Add a purchase before setting its price."
            return false
        }
        if setting.mode == .manual {
            guard let price = setting.manualPricePerGram else {
                var updated = data
                updated.accounts[index].tracking?.metalPricing.removeAll { $0.metal == setting.metal }
                return persist(updated, successMessage: "Metal pricing updated", allowingAssetActivity: true)
            }
            guard !price.isNaN, price > 0, price < 1_000_000_000,
                  let date = setting.asOf, Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: .now) else {
                lastActionStatus = "Enter a positive pure-metal price and a date that is not in the future."
                return false
            }
        } else if setting.automaticPricingConsent != true {
            lastActionStatus = "Confirm the automatic pricing disclosure before enabling price retrieval."
            return false
        }
        var updated = data
        updated.accounts[index].tracking?.metalPricing.removeAll { $0.metal == setting.metal }
        updated.accounts[index].tracking?.metalPricing.append(setting)
        return persist(updated, successMessage: "Metal pricing updated", allowingAssetActivity: true)
    }


    func reconciliation(for accountID: UUID) -> AccountReconciliation? {
        data.reconciliations[accountID]
    }

    @discardableResult
    func updateAccountBalance(
        accountID: UUID,
        targetBalance: Money,
        recordAsTransaction: Bool,
        note: String
    ) -> Bool {
        guard let account = account(with: accountID),
              account.currency == targetBalance.currency else {
            lastActionStatus = "Balance update failed: currency mismatch."
            return false
        }
        guard !isManagedLegacyLoanAccount(accountID) else {
            lastActionStatus = "Update the managed loan balance from Loans."
            return false
        }

        let currentBalance = balance(for: account)
        let difference = targetBalance.minorUnits - currentBalance.minorUnits

        guard difference != 0 else {
            var updated = data
            updated.reconciliations[accountID] = AccountReconciliation(
                lastReconciledAt: .now,
                difference: Money(currency: account.currency, minorUnits: 0)
            )
            return persist(updated, successMessage: "Balance reconciled")
        }

        var updated = data
        if recordAsTransaction {
            let categoryID = Self.balanceAdjustmentCategoryID
            if let categoryIndex = updated.categories.firstIndex(where: { $0.id == categoryID }) {
                updated.categories[categoryIndex].isArchived = false
            } else {
                updated.categories.append(
                    LedgerCategory(
                        id: categoryID,
                        name: "Balance adjustments",
                        systemImage: "arrow.left.arrow.right",
                        includeInTotals: false
                    )
                )
            }

            let adjustmentMoney = Money(
                currency: account.currency,
                minorUnits: Swift.abs(difference)
            )
            let adjustment = LedgerTransaction(
                date: .now,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Balance adjustment"
                    : note.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: difference > 0 ? .income : .expense,
                categoryID: categoryID,
                outflows: difference < 0
                    ? [MoneyMovement(accountID: account.id, money: adjustmentMoney)]
                    : [],
                inflows: difference > 0
                    ? [MoneyMovement(accountID: account.id, money: adjustmentMoney)]
                    : []
            )
            updated.transactions.append(adjustment)
        } else if let accountIndex = updated.accounts.firstIndex(where: { $0.id == accountID }) {
            updated.accounts[accountIndex].openingBalance = Money(
                currency: account.currency,
                minorUnits: account.openingBalance.minorUnits + difference
            )
        }
        updated.reconciliations[accountID] = AccountReconciliation(
            lastReconciledAt: .now,
            difference: Money(currency: account.currency, minorUnits: difference)
        )

        return persist(
            updated,
            successMessage: recordAsTransaction
                ? "Balance adjustment saved as a transaction"
                : "Balance updated without a transaction"
        )
    }

    func availableBalance(for currency: LedgerCurrency) -> Money {
        ledgerIndex.availableBalance(for: currency)
    }

    func loanBalance(for currency: LedgerCurrency) -> Money {
        ledgerIndex.loanBalance(for: currency)
    }

    func assetBalance(for currency: LedgerCurrency) -> Money {
        Money(
            currency: currency,
            minorUnits: availableBalance(for: currency).minorUnits
                + ledgerIndex.lentLoanBalance(for: currency).minorUnits
        )
    }

    func liabilityBalance(for currency: LedgerCurrency) -> Money {
        Money(
            currency: currency,
            minorUnits: loanBalance(for: currency).minorUnits
                + ledgerIndex.borrowedLoanBalance(for: currency).minorUnits
        )
    }

    func netWorth(for currency: LedgerCurrency) -> Money {
        Money(
            currency: currency,
            minorUnits: assetBalance(for: currency).minorUnits - liabilityBalance(for: currency).minorUnits
        )
    }

    func monthlyExpenseTotals() -> [LedgerCurrency: Int64] {
        ledgerIndex.monthlyExpenseTotals(for: .now)
    }

    func categoryPath(for categoryID: UUID?) -> String {
        ledgerIndex.categoryPath(for: categoryID)
    }

    private func validate(
        _ transaction: LedgerTransaction,
        allowArchivedReferences: Bool = false
    ) -> Bool {
        guard let error = FinanceTransactionValidator.validate(
            transaction,
            in: data,
            allowArchivedReferences: allowArchivedReferences
        ) else {
            return true
        }
        lastActionStatus = error.localizedDescription
        return false
    }

    private func wouldCreateCategoryCycle(_ category: LedgerCategory) -> Bool {
        var currentID = category.parentID
        var visited: Set<UUID> = [category.id]

        while let id = currentID {
            guard visited.insert(id).inserted else { return true }
            currentID = data.categories.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    func transactionSummary(
        _ transaction: LedgerTransaction,
        reportingCurrency: LedgerCurrency? = nil
    ) -> String {
        if transaction.kind == .expense {
            let movements = transaction.outflows + transaction.inflows
            let targetCurrency = reportingCurrency
                ?? transaction.amountDue?.currency
                ?? transaction.exchangeRate?.baseCurrency
                ?? movements.first?.money.currency

            if let targetCurrency {
                func convertedTotal(_ movements: [MoneyMovement]) -> Int64? {
                    movements.reduce(Int64.zero) { total, movement in
                        guard let converted = financeConvertedMinorUnits(
                            movement.money,
                            to: targetCurrency,
                            using: transaction.exchangeRate
                        ) else {
                            return total
                        }
                        return total + converted
                    }
                }

                let canConvertEveryMovement = movements.allSatisfy {
                    financeConvertedMinorUnits(
                        $0.money,
                        to: targetCurrency,
                        using: transaction.exchangeRate
                    ) != nil
                }
                if canConvertEveryMovement,
                   let outflowTotal = convertedTotal(transaction.outflows),
                   let inflowTotal = convertedTotal(transaction.inflows) {
                    let net = outflowTotal - inflowTotal
                    guard net != 0 else { return Money(currency: targetCurrency, minorUnits: 0).formatted }
                    return "\(net > 0 ? "−" : "+") \(Money(currency: targetCurrency, minorUnits: Swift.abs(net)).formatted)"
                }
            }

            var currencies: [LedgerCurrency] = []
            for movement in movements where !currencies.contains(movement.money.currency) {
                currencies.append(movement.money.currency)
            }
            let currencySummaries = currencies.compactMap { currency -> String? in
                let outflowTotal = transaction.outflows
                    .filter { $0.money.currency == currency }
                    .reduce(Int64.zero) { $0 + $1.money.minorUnits }
                let inflowTotal = transaction.inflows
                    .filter { $0.money.currency == currency }
                    .reduce(Int64.zero) { $0 + $1.money.minorUnits }
                let net = outflowTotal - inflowTotal
                guard net != 0 else { return nil }
                return "\(net > 0 ? "−" : "+") \(Money(currency: currency, minorUnits: Swift.abs(net)).formatted)"
            }
            return currencySummaries.joined(separator: " · ")
        }

        let outflowText = transaction.outflows.map { $0.money.formatted }.joined(separator: " + ")
        let inflowText = transaction.inflows.map { $0.money.formatted }.joined(separator: " + ")

        if outflowText.isEmpty { return "+ \(inflowText)" }
        if inflowText.isEmpty { return "− \(outflowText)" }
        return "\(outflowText)  →  \(inflowText)"
    }

    private var monthStart: Date {
        Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
    }

    @discardableResult
    private func persist(
        _ proposed: FinanceData,
        successMessage: String?,
        allowingCorruptedReplacement: Bool = false,
        allowingAssetActivity: Bool = false
    ) -> Bool {
        var updated = proposed
        if let error = FinanceAssetTracking.validationError(in: updated) {
            lastActionStatus = error
            return false
        }
        if !allowingAssetActivity && !allowingCorruptedReplacement {
            let linkedIDs = data.accounts.reduce(into: Set<UUID>()) { $0.formUnion($1.tracking?.transactionIDs ?? []) }
            guard data.transactions.filter({ linkedIDs.contains($0.id) }) == updated.transactions.filter({ linkedIDs.contains($0.id) }),
                  data.accounts.filter({ $0.tracking != nil }).allSatisfy({ old in
                      updated.accounts.contains { $0.id == old.id && $0.tracking == old.tracking }
                  }) else {
                lastActionStatus = "Correct linked investment or metal activity from its account tracking history."
                return false
            }
        }
        if allowingAssetActivity
            || data.metalQuotes != updated.metalQuotes
            || data.exchangeRates != updated.exchangeRates {
            recordDailyPhysicalAssetGainHistory(in: &updated)
        }
        guard data != updated else {
            if let successMessage { lastActionStatus = successMessage }
            return true
        }

        let schedulesChanged = data.scheduledTransactions != updated.scheduledTransactions
        let loansChanged = data.loans != updated.loans
        let shortcutInputsChanged = data.accounts != updated.accounts
            || data.categories != updated.categories
            || data.templates != updated.templates
        let spotlightInputsChanged = data.accounts != updated.accounts
            || data.categories != updated.categories
            || data.transactions != updated.transactions
        let persisted = storage.save(
            updated,
            expected: data,
            allowingCorruptedReplacement: allowingCorruptedReplacement
        )
        guard persisted else {
            if storage.saveConflict {
                replaceData(storage.load())
                let action = successMessage ?? "Daily physical asset history"
                lastActionStatus = "\(action) was not saved because the ledger changed in another surface. Reloaded the latest data."
                return false
            }
            let reason = storage.isCorrupted
                ? "the persistent database could not be decoded; restore or reset it"
                : "the persistent database is unavailable"
            let action = successMessage ?? "Daily physical asset history"
            lastActionStatus = "\(action) was not saved because \(reason)."
            return false
        }

        replaceData(updated)
        WidgetCenter.shared.reloadTimelines(ofKind: "BalanceWidget")
        if shortcutInputsChanged {
            PocketLedgerShortcuts.updateAppShortcutParameters()
        }
        if spotlightInputsChanged {
            Task {
                await FinanceIntentIndexing.shared.refresh()
            }
        }
        if schedulesChanged {
            let schedules = updated.scheduledTransactions
            Task {
                await NotificationService.refreshScheduledTransactionNotifications(
                    schedules: schedules
                )
            }
        }
        if loansChanged {
            let loans = updated.loans
            Task {
                await NotificationService.refreshLoanNotifications(loans: loans)
            }
        }
        if let successMessage { lastActionStatus = successMessage }
        return true
    }

    private func recordDailyPhysicalAssetGainHistory(in updated: inout FinanceData) {
        let date = Calendar.current.startOfDay(for: .now)
        let index = LedgerIndex(data: updated)

        for accountIndex in updated.accounts.indices {
            var account = updated.accounts[accountIndex]
            guard !account.isArchived,
                  account.type == .physicalAsset,
                  var tracking = account.tracking else { continue }

            let gainLoss = FinanceAssetTracking.gainLoss(
                account: account,
                recordedBalance: index.balance(for: account),
                data: updated
            )
            let gainLossByMetal = Dictionary(uniqueKeysWithValues: PreciousMetal.allCases.compactMap { metal in
                FinanceAssetTracking.gainLoss(account: account, metal: metal, data: updated)
                    .map { (metal, $0) }
            })
            guard gainLoss != nil || !gainLossByMetal.isEmpty else { continue }

            var history = tracking.physicalAssetGainHistory ?? []
            let snapshot = PhysicalAssetGainSnapshot(
                date: date,
                gainLoss: gainLoss,
                gainLossByMetal: gainLossByMetal.isEmpty ? nil : gainLossByMetal
            )
            if let snapshotIndex = history.firstIndex(where: {
                Calendar.current.isDate($0.date, inSameDayAs: date)
            }) {
                history[snapshotIndex] = snapshot
            } else {
                history.append(snapshot)
            }
            history.sort { $0.date < $1.date }
            guard tracking.physicalAssetGainHistory != history else { continue }
            tracking.physicalAssetGainHistory = history
            account.tracking = tracking
            updated.accounts[accountIndex] = account
        }
    }

    private func replaceData(_ updated: FinanceData) {
        guard data != updated else { return }
        let indexInputsChanged = data.accounts != updated.accounts
            || data.categories != updated.categories
            || data.transactions != updated.transactions
            || data.loans != updated.loans
            || data.metalQuotes != updated.metalQuotes
            || data.exchangeRates != updated.exchangeRates
        data = updated
        if indexInputsChanged {
            ledgerIndex = LedgerIndex(data: updated)
        }
        ledgerRevision &+= 1
    }

    private func validateImportedData(_ imported: FinanceData) -> Bool {
        guard let error = FinanceDataValidator.validate(imported) else {
            return true
        }
        lastActionStatus = "Import rejected: \(error.localizedDescription)"
        return false
    }
}
