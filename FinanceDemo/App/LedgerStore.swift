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
    @Published private(set) var data: FinanceData
    @Published private(set) var lastActionStatus: String?
    @Published private(set) var ledgerRevision = 0

    private let storage = FinanceStorage(context: "main-app")
    private(set) var ledgerIndex: LedgerIndex

    init() {
        let loadedData = storage.load()
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

        guard validate(transaction, allowArchivedReferences: true) else { return false }

        var updated = data
        updated.transactions[index] = transaction
        return persist(updated, successMessage: "Transaction updated")
    }

    @discardableResult
    func deleteTransaction(id: UUID) -> Bool {
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
        updated.transactions.removeAll { ids.contains($0.id) }
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
        guard validate(scheduledTransaction.transactionTemplate) else { return false }
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
        guard let index = data.scheduledTransactions.firstIndex(where: { $0.id == scheduledTransaction.id }) else {
            lastActionStatus = "Scheduled transaction not found"
            return false
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
        guard let index = data.scheduledTransactions.firstIndex(where: { $0.id == id }) else {
            lastActionStatus = "Scheduled transaction not found"
            return false
        }

        var scheduledTransaction = data.scheduledTransactions[index]
        guard !(isEnabled && scheduledTransaction.frequency == .once && scheduledTransaction.lastRunDate != nil) else {
            lastActionStatus = "Completed one-time transactions cannot be re-enabled"
            return false
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

    @discardableResult
    func addAccount(_ account: Account) -> Bool {
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastActionStatus = "Enter an account name"
            return false
        }
        var updated = data
        updated.accounts.append(account)
        return persist(updated, successMessage: "Account added")
    }

    @discardableResult
    func updateAccount(_ account: Account) -> Bool {
        guard let index = data.accounts.firstIndex(where: { $0.id == account.id }) else {
            lastActionStatus = "Account not found"
            return false
        }
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastActionStatus = "Enter an account name"
            return false
        }
        let original = data.accounts[index]

        var updated = original.currency == account.currency
            ? data
            : FinanceAccountCurrencyMigration.migrating(
                data,
                accountID: account.id,
                from: original.currency,
                to: account.currency
            )
        updated.accounts[index] = account
        return persist(updated, successMessage: "Account updated")
    }

    @discardableResult
    func setAccountArchived(accountID: UUID, isArchived: Bool) -> Bool {
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID }) else {
            lastActionStatus = "Account not found"
            return false
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
        guard budget.monthlyLimit.minorUnits > 0,
              data.categories.contains(where: { $0.id == budget.categoryID }),
              budget.monthlyLimit.currency == budget.currency else {
            lastActionStatus = "Enter a valid budget"
            return false
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
        let templateIDs = Set(updated.templates.map(\.id))
        let attachmentIDs = Set(updated.attachments.map(\.id))

        updated.accounts.append(contentsOf: imported.accounts.filter { !accountIDs.contains($0.id) })
        updated.categories.append(contentsOf: imported.categories.filter { !categoryIDs.contains($0.id) })
        updated.transactions.append(contentsOf: imported.transactions.filter { !transactionIDs.contains($0.id) })
        updated.scheduledTransactions.append(
            contentsOf: imported.scheduledTransactions.filter { !scheduledTransactionIDs.contains($0.id) }
        )
        updated.budgets.append(contentsOf: imported.budgets.filter { !budgetIDs.contains($0.id) })
        updated.templates.append(contentsOf: imported.templates.filter { !templateIDs.contains($0.id) })
        updated.attachments.append(contentsOf: imported.attachments.filter { !attachmentIDs.contains($0.id) })
        for rate in imported.exchangeRates {
            updated.exchangeRates.removeAll {
                Set([$0.baseCurrency, $0.quoteCurrency]) == Set([rate.baseCurrency, rate.quoteCurrency])
            }
            updated.exchangeRates.append(rate)
        }

        guard validateImportedData(updated) else { return false }
        return persist(updated, successMessage: "Import completed")
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
                categoryID: nil,
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
        availableBalance(for: currency)
    }

    func liabilityBalance(for currency: LedgerCurrency) -> Money {
        loanBalance(for: currency)
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

    func transactionSummary(_ transaction: LedgerTransaction) -> String {
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
        _ updated: FinanceData,
        successMessage: String,
        allowingCorruptedReplacement: Bool = false
    ) -> Bool {
        guard data != updated else {
            lastActionStatus = successMessage
            return true
        }

        let schedulesChanged = data.scheduledTransactions != updated.scheduledTransactions
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
                lastActionStatus = "\(successMessage) was not saved because the ledger changed in another surface. Reloaded the latest data."
                return false
            }
            let reason = storage.isCorrupted
                ? "the persistent database could not be decoded; restore or reset it"
                : "the persistent database is unavailable"
            lastActionStatus = "\(successMessage) was not saved because \(reason)."
            return false
        }

        replaceData(updated)
        WidgetCenter.shared.reloadTimelines(ofKind: "BalanceWidget")
        if shortcutInputsChanged {
            FinanceDemoShortcuts.updateAppShortcutParameters()
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
        lastActionStatus = successMessage
        return true
    }

    private func replaceData(_ updated: FinanceData) {
        guard data != updated else { return }
        let indexInputsChanged = data.accounts != updated.accounts
            || data.categories != updated.categories
            || data.transactions != updated.transactions
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
