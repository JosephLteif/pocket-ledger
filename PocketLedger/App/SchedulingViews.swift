import SwiftUI

private struct RecurringScheduleSuggestion: Identifiable {
    let schedule: ScheduledTransaction
    let occurrenceCount: Int
    var id: UUID { schedule.id }
}

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
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false

    @State private var editorRoute: ScheduledEditorRoute?
    @State private var scheduleToDelete: ScheduledTransaction?
    @State private var isShowingDeleteConfirmation = false
    @State private var reminderStatus: String?
    @State private var recordStatus: String?
    @State private var recordUndoReceipt: ScheduleRecordUndoReceipt?
    @State private var isRequestingReminderPermission = false
    @AppStorage(NotificationService.globalReminderKey)
    private var globalReminderRawValue = ScheduledReminderTiming.oneDayBefore.rawValue

    var body: some View {
        List {
            Text("Plan bills, income, and recurring transfers")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Text("Due entries are added to Transactions when Pocket Ledger opens or returns to the foreground.")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            globalReminderSettings
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if !schedules.isEmpty {
                scheduledReminderSettings
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let reminderStatus {
                Text(reminderStatus)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !recurringSuggestions.isEmpty {
                Section {
                    ForEach(recurringSuggestions) { suggestion in
                        recurringSuggestionCard(suggestion)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Possible recurring expenses")
                } footer: {
                    Text("Suggestions are based only on transactions saved on this device.")
                }
                .listSectionSeparator(.hidden)
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
            ToolbarItem(placement: .primaryAction) {
                Button(action: presentNewSchedule) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add scheduled transaction")
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

    private var globalReminderSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reminder timing", systemImage: "bell.badge")
                .font(.headline)
                .foregroundStyle(PocketLedgerTheme.textPrimary)

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
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PocketLedgerTheme.textPrimary)
                        Text("Used when a schedule has no override")
                            .font(.caption)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(globalReminderTiming.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.accent)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .padding(14)
        .pocketGroupedSurface(cornerRadius: 18)
    }

    private var scheduledReminderSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(PocketLedgerTheme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Scheduled reminders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                    Text("Get notified before enabled entries are due.")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }

            Button {
                Task {
                    isRequestingReminderPermission = true
                    defer { isRequestingReminderPermission = false }
                    reminderStatus = await NotificationService
                        .requestScheduledTransactionNotifications(schedules: schedules)
                }
            } label: {
                Group {
                    if isRequestingReminderPermission {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Requesting access…")
                        }
                    } else {
                        Label("Enable scheduled reminders", systemImage: "bell.badge")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(PocketLedgerTheme.accent)
            .disabled(isRequestingReminderPermission)
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

    private var recurringSuggestions: [RecurringScheduleSuggestion] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .month, value: -6, to: .now) ?? .distantPast
        let transactions = store.data.transactions.filter { transaction in
            transaction.kind == .expense
                && transaction.inflows.isEmpty
                && transaction.outflows.count == 1
                && store.account(with: transaction.outflows[0].accountID)?.isArchived == false
                && transaction.exchangeRate == nil
                && !transaction.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && transaction.date >= cutoff
        }
        let groups = Dictionary(grouping: transactions) { transaction in
            let movement = transaction.outflows[0]
            let note = transaction.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "\(note)|\(transaction.categoryID?.uuidString ?? "")|\(movement.accountID)|\(movement.money.currency.rawValue)|\(movement.money.minorUnits)"
        }

        return groups.values.compactMap { group -> RecurringScheduleSuggestion? in
            let sorted = group.sorted { $0.date < $1.date }
            guard sorted.count >= 3 else { return nil }
            let gaps = zip(sorted, sorted.dropFirst()).compactMap { first, second in
                calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: second.date)).day
            }
            guard !gaps.isEmpty else { return nil }
            let frequency: ScheduleFrequency
            if gaps.allSatisfy({ (6...8).contains($0) }) {
                frequency = .weekly
            } else if gaps.allSatisfy({ (25...35).contains($0) }) {
                frequency = .monthly
            } else {
                return nil
            }

            guard let latest = sorted.last,
                  let nextDate = frequency.nextDate(
                    after: latest.date,
                    calendar: calendar,
                    monthlyDay: calendar.component(.day, from: latest.date)
                  ) else { return nil }
            let movement = latest.outflows[0]
            let isAlreadyScheduled = schedules.contains { schedule in
                schedule.kind == .expense
                    && schedule.frequency != .once
                    && schedule.categoryID == latest.categoryID
                    && schedule.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        == latest.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    && schedule.outflows.count == 1
                    && schedule.outflows[0].accountID == movement.accountID
                    && schedule.outflows[0].money == movement.money
            }
            guard !isAlreadyScheduled else { return nil }

            return RecurringScheduleSuggestion(
                schedule: ScheduledTransaction(
                    nextRunDate: nextDate,
                    frequency: frequency,
                    recurrenceDay: calendar.component(.day, from: latest.date),
                    note: latest.note,
                    kind: .expense,
                    categoryID: latest.categoryID,
                    amountDue: latest.amountDue,
                    outflows: latest.outflows,
                    inflows: [],
                    exchangeRate: latest.exchangeRate,
                    changeAdjustment: latest.changeAdjustment
                ),
                occurrenceCount: sorted.count
            )
        }
        .sorted { $0.occurrenceCount > $1.occurrenceCount }
        .prefix(3)
        .map { $0 }
    }

    private func recurringSuggestionCard(_ suggestion: RecurringScheduleSuggestion) -> some View {
        let schedule = suggestion.schedule
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.note)
                        .font(.headline)
                        .lineLimit(2)
                    ProtectedAmountText(
                        value: store.transactionSummary(schedule.transactionTemplate),
                        isRevealed: areBalancesRevealed
                    )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PocketLedgerTheme.textPrimary)
                }
                Spacer()
                Text("\(suggestion.occurrenceCount) entries")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
            Text(store.categoryPath(for: schedule.categoryID))
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
                .lineLimit(1)
            Text("\(schedule.frequency.displayName) · Next \(schedule.nextRunDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
            if let accountID = schedule.outflows.first?.accountID,
               let account = store.account(with: accountID) {
                Label(account.name, systemImage: "wallet.pass")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .lineLimit(1)
            }
            Button {
                guard store.addScheduledTransaction(schedule) else { return }
                recordStatus = "Recurring schedule created"
                recordUndoReceipt = nil
            } label: {
                Label("Create schedule", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(PocketLedgerTheme.accent)
        }
        .padding(14)
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
                    ProtectedAmountText(
                        value: store.transactionSummary(schedule.transactionTemplate),
                        isRevealed: areBalancesRevealed
                    )
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

            Text(timingText(for: schedule))
                .font(.caption.weight(.semibold))
                .foregroundStyle(schedule.isEnabled ? PocketLedgerTheme.accent : PocketLedgerTheme.textTertiary)

            HStack(spacing: 10) {
                if schedule.isEnabled {
                    Button {
                        recordNow(id: schedule.id)
                    } label: {
                        Label("Record", systemImage: "checkmark.circle")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(PocketLedgerTheme.positive)
                    .accessibilityLabel("Record now")
                }

                Button {
                    editorRoute = .edit(schedule)
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(PocketLedgerTheme.accent)

                Spacer()

                Menu {
                    Button(
                        schedule.isEnabled ? "Pause schedule" : "Enable schedule",
                        systemImage: schedule.isEnabled ? "pause.circle" : "play.circle"
                    ) {
                        _ = store.setScheduledTransactionEnabled(
                            id: schedule.id,
                            isEnabled: !schedule.isEnabled
                        )
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
                    Label("More", systemImage: "ellipsis")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                PocketSwipeActionButton(
                    title: "Record now",
                    systemImage: "checkmark.circle",
                    tint: PocketLedgerTheme.positive
                ) {
                    recordNow(id: schedule.id)
                }

                PocketSwipeActionButton(
                    title: "Skip next",
                    systemImage: "forward.end",
                    tint: PocketLedgerTheme.textSecondary
                ) {
                    _ = store.skipNextScheduledTransaction(id: schedule.id)
                }
            } else if !isCompletedOneTime(schedule) {
                PocketSwipeActionButton(
                    title: "Enable",
                    systemImage: "play.circle",
                    tint: PocketLedgerTheme.positive
                ) {
                    _ = store.setScheduledTransactionEnabled(id: schedule.id, isEnabled: true)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            PocketSwipeActionButton(
                title: "Edit",
                systemImage: "pencil",
                tint: .yellow
            ) {
                editorRoute = .edit(schedule)
            }

            PocketSwipeActionButton(
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
}
