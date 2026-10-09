import SwiftUI

private enum ScheduledEditorRoute: Identifiable {
    case new
    case edit(ScheduledTransaction)

    var id: String {
        switch self {
        case .new:
            return "new"
        case .edit(let schedule):
            return "edit-\(schedule.id)"
        }
    }

    var schedule: ScheduledTransaction? {
        guard case .edit(let schedule) = self else { return nil }
        return schedule
    }
}

@MainActor
struct ScheduledTransactionsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @ObservedObject private var proAccess = ProEntitlementStore.shared

    @State private var editorRoute: ScheduledEditorRoute?
    @State private var scheduleToDelete: ScheduledTransaction?
    @State private var isShowingDeleteConfirmation = false
    @State private var reminderStatus: String?
    @State private var recordStatus: String?
    @State private var recordUndoReceipt: ScheduleRecordUndoReceipt?
    @State private var isRequestingReminderPermission = false
    @State private var isShowingProUpgrade = false
    @State private var recurringCostIsYearly = false
    @AppStorage(NotificationService.globalReminderKey)
    private var globalReminderRawValue = ScheduledReminderTiming.oneDayBefore.rawValue

    var body: some View {
        List {
            Text("Manage bills, subscriptions, income, and recurring transfers")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Text("Due entries are added to Transactions when Pocket Ledger opens or returns to the foreground.")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Text(proAccess.hasProAccess
                 ? "\(enabledScheduleCount) enabled schedules"
                 : "\(enabledScheduleCount) of \(PocketLedgerTierPolicy.freeEnabledScheduleLimit) enabled schedules")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !proAccess.hasProAccess,
               enabledScheduleCount >= PocketLedgerTierPolicy.freeEnabledScheduleLimit {
                ProUpgradePrompt(
                    title: "Need more schedules?",
                    detail: "Pro removes the limit on enabled scheduled transactions.",
                    feature: .schedules
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            reminderSettings
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !recurringExpenseAnnualTotals.isEmpty {
                recurringExpenseSummary
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if schedules.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(schedules) { schedule in
                    scheduleCard(schedule)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .pocketScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let recordStatus {
                HStack(spacing: 12) {
                    Text(recordStatus)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if recordUndoReceipt != nil {
                        Button("Undo", action: undoRecordedSchedule)
                            .font(.footnote.weight(.semibold))
                    }
                    Button {
                        self.recordStatus = nil
                        recordUndoReceipt = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .accessibilityLabel("Dismiss schedule status")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Scheduled")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: presentNewSchedule) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add scheduled transaction")
                }
            }
        }
        .background {
            Color.clear.sheet(isPresented: $isShowingProUpgrade) {
                ProUpgradeView(access: proAccess)
            }
        }
        .sheet(item: $editorRoute) { route in
            TransactionEditor(
                store: store,
                initialTiming: .scheduled,
                scheduledTransaction: route.schedule
            )
        }
        .confirmationDialog(
            "Delete scheduled transaction?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible,
            presenting: scheduleToDelete
        ) { schedule in
            Button("Delete", role: .destructive) {
                _ = store.deleteScheduledTransaction(id: schedule.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This scheduled transaction will be removed.")
        }
        .onChange(of: isShowingDeleteConfirmation) { _, isPresented in
            if !isPresented {
                scheduleToDelete = nil
            }
        }
        .onChange(of: globalReminderRawValue) { _, _ in
            Task {
                await NotificationService.refreshScheduledTransactionNotifications(
                    schedules: schedules
                )
                await NotificationService.refreshLoanNotifications(loans: store.data.loans)
            }
        }
    }

    private var globalReminderTiming: ScheduledReminderTiming {
        ScheduledReminderTiming(rawValue: globalReminderRawValue) ?? .oneDayBefore
    }

    private var enabledScheduleCount: Int {
        store.data.scheduledTransactions.filter(\.isEnabled).count
    }

    private var reminderSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Reminders", systemImage: "bell.badge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textPrimary)

                Spacer(minLength: 4)

                Menu {
                    ForEach(ScheduledReminderTiming.allCases) { timing in
                        Button {
                            globalReminderRawValue = timing.rawValue
                        } label: {
                            if timing == globalReminderTiming {
                                Label(timing.title, systemImage: "checkmark")
                            } else {
                                Text(timing.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("Default · \(globalReminderTiming.title)")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(PocketLedgerTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Default reminder timing: \(globalReminderTiming.title)")

                if !schedules.isEmpty {
                    Button {
                        Task {
                            isRequestingReminderPermission = true
                            defer { isRequestingReminderPermission = false }
                            reminderStatus = await NotificationService
                                .requestScheduledTransactionNotifications(schedules: schedules)
                        }
                    } label: {
                        if isRequestingReminderPermission {
                            ProgressView()
                                .frame(width: 18, height: 18)
                        } else {
                            Label("Enable", systemImage: "bell.badge")
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(PocketLedgerTheme.accent)
                    .disabled(isRequestingReminderPermission)
                    .accessibilityLabel("Enable scheduled reminders")
                }
            }

            if let reminderStatus {
                Text(reminderStatus)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
        }
        .padding(14)
        .pocketGroupedSurface(cornerRadius: 18)
    }

    private var schedules: [ScheduledTransaction] {
        store.data.scheduledTransactions.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            return lhs.nextRunDate < rhs.nextRunDate
        }
    }

    private var recurringExpenses: [ScheduledTransaction] {
        store.data.scheduledTransactions.filter { isRecurringExpense($0) }
    }

    private var recurringExpenseAnnualTotals: [LedgerCurrency: Decimal] {
        var totals: [LedgerCurrency: Decimal] = [:]
        for schedule in recurringExpenses {
            let annualMultiplier = annualMultiplier(for: schedule.frequency)
            for charge in chargeAmounts(for: schedule) {
                totals[charge.currency, default: .zero] += Decimal(charge.minorUnits) * annualMultiplier
            }
        }
        return totals
    }

    private var recurringExpenseSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estimated cost")
                .font(.headline)
            Picker("Estimate period", selection: $recurringCostIsYearly) {
                Text("Monthly").tag(false)
                Text("Yearly").tag(true)
            }
            .pickerStyle(.segmented)

            ForEach(LedgerCurrency.allCases.filter { recurringExpenseAnnualTotals[$0] != nil }) { currency in
                LabeledContent(
                    currency.rawValue,
                    value: formatted(
                        (recurringExpenseAnnualTotals[currency] ?? .zero) / (recurringCostIsYearly ? 1 : 12),
                        currency: currency
                    )
                )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Text("Estimates use each schedule’s frequency. Price changes are matched by exact transaction name and currency.")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 18)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(PocketLedgerTheme.textTertiary)
            Text("Nothing scheduled yet")
                .font(.headline)
            Text("Create a future or recurring transaction and it will be recorded automatically when the app is active.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Create schedule", action: presentNewSchedule)
                .buttonStyle(.glassProminent)
                .tint(PocketLedgerTheme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 20)
        .pocketGroupedSurface(cornerRadius: 20)
    }

    private func scheduleCard(_ schedule: ScheduledTransaction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.note.isEmpty ? schedule.kind.displayName : schedule.note)
                        .font(.headline)
                        .lineLimit(2)
                    Text(store.transactionSummary(schedule.transactionTemplate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                }

                Spacer(minLength: 8)

                Label(
                    schedule.isEnabled ? "Enabled" : "Paused",
                    systemImage: schedule.isEnabled ? "checkmark.circle.fill" : "pause.circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(schedule.isEnabled ? PocketLedgerTheme.positive : PocketLedgerTheme.textTertiary)
                .labelStyle(.titleAndIcon)

            }

            HStack(spacing: 8) {
                Label(schedule.kind.displayName, systemImage: schedule.kind == .income ? "arrow.down.left" : "arrow.up.right")
                if schedule.kind == .expense {
                    Text("·")
                    Text(store.categoryPath(for: schedule.categoryID))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(PocketLedgerTheme.textSecondary)

            Label(scheduleAccountSummary(for: schedule), systemImage: "wallet.pass")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .lineLimit(1)

            if isRecurringExpense(schedule), !chargeAmounts(for: schedule).isEmpty {
                recurringExpenseDetails(schedule)
            }

            Text(timingText(for: schedule))
                .font(.caption.weight(.semibold))
                .foregroundStyle(schedule.isEnabled ? PocketLedgerTheme.accent : PocketLedgerTheme.textTertiary)

            HStack(spacing: 8) {
                if schedule.isEnabled {
                    Button {
                        recordNow(id: schedule.id)
                    } label: {
                        Label("Record now", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(PocketLedgerTheme.positive)
                }

                Spacer(minLength: 8)

                Button {
                    editorRoute = .edit(schedule)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(PocketLedgerTheme.accent)
                .accessibilityLabel("Edit scheduled transaction")

                Menu {
                    Button(
                        schedule.isEnabled ? "Pause schedule" : "Enable schedule",
                        systemImage: schedule.isEnabled ? "pause.circle" : "play.circle"
                    ) {
                        setScheduleEnabled(id: schedule.id, isEnabled: !schedule.isEnabled)
                    }
                    .disabled(isCompletedOneTime(schedule))

                    Menu("Reminder · \(reminderLabel(for: schedule))", systemImage: "bell") {
                        Button {
                            updateReminder(for: schedule, timing: nil)
                        } label: {
                            if schedule.reminderTiming == nil {
                                Label("Default · \(globalReminderTiming.title)", systemImage: "checkmark")
                            } else {
                                Text("Default · \(globalReminderTiming.title)")
                            }
                        }

                        ForEach(ScheduledReminderTiming.allCases) { timing in
                            Button {
                                updateReminder(for: schedule, timing: timing)
                            } label: {
                                if schedule.reminderTiming == timing {
                                    Label(timing.title, systemImage: "checkmark")
                                } else {
                                    Text(timing.title)
                                }
                            }
                        }
                    }

                    if schedule.isEnabled {
                        Button("Skip next", systemImage: "forward.end") {
                            _ = store.skipNextScheduledTransaction(id: schedule.id)
                        }
                    }
                    Button(role: .destructive) {
                        scheduleToDelete = schedule
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete schedule", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("More scheduled transaction actions")
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if schedule.isEnabled {
                PocketCircularSwipeAction(
                    title: "Record now",
                    systemImage: "checkmark.circle",
                    tint: PocketLedgerTheme.positive
                ) {
                    recordNow(id: schedule.id)
                }

                PocketCircularSwipeAction(
                    title: "Skip next",
                    systemImage: "forward.end",
                    tint: PocketLedgerTheme.textSecondary
                ) {
                    _ = store.skipNextScheduledTransaction(id: schedule.id)
                }
            } else if !isCompletedOneTime(schedule) {
                PocketCircularSwipeAction(
                    title: "Enable",
                    systemImage: "play.circle",
                    tint: PocketLedgerTheme.positive
                ) {
                    setScheduleEnabled(id: schedule.id, isEnabled: true)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            PocketCircularSwipeAction(
                title: "Edit",
                systemImage: "pencil",
                tint: .yellow,
                iconColor: .black
            ) {
                editorRoute = .edit(schedule)
            }

            PocketCircularSwipeAction(
                title: "Delete",
                systemImage: "trash",
                tint: .red,
                role: .destructive
            ) {
                scheduleToDelete = schedule
                isShowingDeleteConfirmation = true
            }
        }
    }

    private func recurringExpenseDetails(_ schedule: ScheduledTransaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chargeAmounts(for: schedule), id: \.currency) { charge in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            recurringCostIsYearly ? "Estimated yearly" : "Estimated monthly",
                            systemImage: "arrow.clockwise"
                        )
                            .font(.caption)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                        Spacer(minLength: 8)
                        Text(formatted(
                            Decimal(charge.minorUnits) * annualMultiplier(for: schedule.frequency)
                                / (recurringCostIsYearly ? 1 : 12),
                            currency: charge.currency
                        ))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                    }

                    if let change = priceChange(for: schedule, currency: charge.currency) {
                        Label("Changed from \(change.previous.formatted) to \(change.current.formatted)", systemImage: "arrow.left.arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketLedgerTheme.warning)
                    }
                }
            }
        }
    }

    private func isRecurringExpense(_ schedule: ScheduledTransaction) -> Bool {
        schedule.isEnabled && schedule.frequency != .once && schedule.kind == .expense
    }

    private func annualMultiplier(for frequency: ScheduleFrequency) -> Decimal {
        switch frequency {
        case .once: .zero
        case .daily: 365
        case .weekly: 52
        case .monthly: 12
        case .yearly: 1
        }
    }

    private func chargeAmounts(for schedule: ScheduledTransaction) -> [Money] {
        if let amountDue = schedule.amountDue, amountDue.minorUnits > 0 {
            return [amountDue]
        }

        let currencies = Set(schedule.outflows.map { $0.money.currency })
        return currencies.sorted { $0.rawValue < $1.rawValue }.compactMap { currency in
            let outflow = schedule.outflows
                .filter { $0.money.currency == currency }
                .reduce(Int64.zero) { $0 + $1.money.minorUnits }
            let inflow = schedule.inflows
                .filter { $0.money.currency == currency }
                .reduce(Int64.zero) { $0 + $1.money.minorUnits }
            let charge = max(outflow - inflow, 0)
            return charge > 0 ? Money(currency: currency, minorUnits: charge) : nil
        }
    }

    private func priceChange(
        for schedule: ScheduledTransaction,
        currency: LedgerCurrency
    ) -> (previous: Money, current: Money)? {
        let normalizedNote = schedule.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingTransactions = store.data.transactions
            .filter {
                $0.kind == .expense
                    && $0.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedNote
                    && $0.date <= .now
            }
            .sorted { $0.date > $1.date }

        let amounts = matchingTransactions.compactMap { transaction -> Money? in
            if let due = transaction.amountDue, due.currency == currency, due.minorUnits > 0 {
                return due
            }
            let outflow = transaction.outflows
                .filter { $0.money.currency == currency }
                .reduce(Int64.zero) { $0 + $1.money.minorUnits }
            let inflow = transaction.inflows
                .filter { $0.money.currency == currency }
                .reduce(Int64.zero) { $0 + $1.money.minorUnits }
            let charge = max(outflow - inflow, 0)
            return charge > 0 ? Money(currency: currency, minorUnits: charge) : nil
        }
        if let scheduledAmount = chargeAmounts(for: schedule).first(where: { $0.currency == currency }),
           let latestAmount = amounts.first,
           scheduledAmount.minorUnits != latestAmount.minorUnits {
            return (latestAmount, scheduledAmount)
        }
        guard amounts.count >= 2, amounts[0].minorUnits != amounts[1].minorUnits else { return nil }
        return (amounts[1], amounts[0])
    }

    private func formatted(_ amount: Decimal, currency: LedgerCurrency) -> String {
        var rounded = Decimal()
        var annualAmount = amount
        NSDecimalRound(&rounded, &annualAmount, 0, .plain)
        return Money(currency: currency, minorUnits: NSDecimalNumber(decimal: rounded).int64Value).formatted
    }

    private func recordNow(id: UUID) {
        guard let receipt = store.recordScheduledTransactionNow(id: id) else {
            recordUndoReceipt = nil
            recordStatus = store.lastActionStatus ?? "The scheduled transaction could not be recorded."
            return
        }
        recordUndoReceipt = receipt
        recordStatus = store.lastActionStatus ?? "Scheduled transaction recorded."
    }

    private func undoRecordedSchedule() {
        guard let receipt = recordUndoReceipt else { return }
        let didUndo = store.undoScheduledTransactionRecord(receipt)
        recordUndoReceipt = nil
        recordStatus = store.lastActionStatus
            ?? (didUndo ? "Scheduled transaction undone." : "Undo is no longer available.")
    }

    private func scheduleAccountSummary(for schedule: ScheduledTransaction) -> String {
        let sourceAccounts = schedule.outflows.compactMap { store.account(with: $0.accountID)?.name }
        let destinationAccounts = schedule.inflows.compactMap { store.account(with: $0.accountID)?.name }
        let source = sourceAccounts.joined(separator: ", ")
        let destination = destinationAccounts.joined(separator: ", ")
        if !source.isEmpty, !destination.isEmpty {
            return "\(source) → \(destination)"
        }
        if !source.isEmpty { return source }
        return destination.isEmpty ? "Account unavailable" : destination
    }

    private func timingText(for schedule: ScheduledTransaction) -> String {
        let date = schedule.nextRunDate.formatted(date: .abbreviated, time: .shortened)
        if let skippedDate = schedule.lastSkippedDate,
           schedule.lastRunDate.map({ skippedDate > $0 }) ?? true {
            if schedule.frequency == .once {
                return "Skipped \(skippedDate.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Skipped \(skippedDate.formatted(date: .abbreviated, time: .shortened)) · Next \(date)"
        }
        if schedule.isEnabled {
            if schedule.frequency == .once {
                return "Runs on \(date)"
            }
            if schedule.frequency == .monthly,
               schedule.monthlyRule == .lastDayOfMonth {
                return "Next \(date) · Last day of each month"
            }
            return "Next \(date) · \(schedule.frequency.displayName)"
        }

        if isCompletedOneTime(schedule), let lastRunDate = schedule.lastRunDate {
            return "Completed \(lastRunDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Paused · Next \(date)"
    }

    private func isCompletedOneTime(_ schedule: ScheduledTransaction) -> Bool {
        schedule.frequency == .once && schedule.lastRunDate != nil
    }

    private func reminderLabel(for schedule: ScheduledTransaction) -> String {
        schedule.reminderTiming?.title ?? "Default · \(globalReminderTiming.title)"
    }

    private func updateReminder(
        for schedule: ScheduledTransaction,
        timing: ScheduledReminderTiming?
    ) {
        var updated = schedule
        updated.reminderTiming = timing
        _ = store.updateScheduledTransaction(updated)
    }

    private func presentNewSchedule() {
        editorRoute = .new
    }

    private func setScheduleEnabled(id: UUID, isEnabled: Bool) {
        guard !store.setScheduledTransactionEnabled(id: id, isEnabled: isEnabled),
              let feature = store.proAccessRequired else {
            return
        }
        proAccess.requestUpgrade(for: feature)
        isShowingProUpgrade = true
    }
}
