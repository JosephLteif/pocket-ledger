import SwiftUI

struct WatchHomeView: View {
    @ObservedObject var store: WatchLedgerStore
    @State private var isShowingExpense = false
    private let staleSyncInterval: TimeInterval = 24 * 60 * 60

    private var balanceUpdatedAt: Date? {
        store.snapshot?.generatedAt ?? store.lastSyncedAt
    }

    private var isSnapshotStale: Bool {
        guard let balanceUpdatedAt else { return false }
        return Date.now.timeIntervalSince(balanceUpdatedAt) >= staleSyncInterval
    }

    var body: some View {
        NavigationStack {
            List {
                if store.status != .synced || isSnapshotStale || store.errorMessage != nil {
                    Section {
                        Label(
                            isSnapshotStale
                                ? "Balances may be out of date"
                                : store.status.title,
                            systemImage: isSnapshotStale
                                ? "clock.badge.exclamationmark"
                                : store.status.systemImage
                        )
                        .foregroundStyle(store.status == .error || isSnapshotStale ? Color.orange : Color.secondary)

                        if isSnapshotStale && store.status != .synced {
                            Text(store.status.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let balanceUpdatedAt {
                            Text("Data from \(balanceUpdatedAt, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage = store.errorMessage {
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button {
                        isShowingExpense = true
                    } label: {
                        Label("Add expense", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.snapshot?.accounts.contains(where: \.canUseForExpense) != true)

                    if !store.pendingExpenses.isEmpty {
                        NavigationLink {
                            WatchPendingExpensesView(store: store)
                        } label: {
                            Label(
                                "\(store.pendingExpenses.count) queued expense\(store.pendingExpenses.count == 1 ? "" : "s")",
                                systemImage: store.failedExpenseMessages.isEmpty ? "clock" : "exclamationmark.circle.fill"
                            )
                            .foregroundStyle(store.failedExpenseMessages.isEmpty ? Color.secondary : Color.orange)
                        }
                    }
                }

                if let snapshot = store.snapshot {
                    Section {
                        ForEach(snapshot.balances) { balance in
                            HStack {
                                Text(balance.currency.rawValue)
                                Spacer()
                                Text(balance.balance.formatted)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .privacySensitive()
                            }
                        }
                    } header: {
                        HStack {
                            Text("Balances")
                            Spacer()
                            if let balanceUpdatedAt {
                                Text("Updated \(balanceUpdatedAt, style: .relative)")
                            }
                        }
                    }

                    if snapshot.attentionCount > 0 || snapshot.upcomingScheduledCount > 0 {
                        Section("Planning") {
                            if snapshot.attentionCount > 0 {
                                Label(
                                    "\(snapshot.attentionCount) item\(snapshot.attentionCount == 1 ? "" : "s") needs attention",
                                    systemImage: "exclamationmark.circle"
                                )
                                .foregroundStyle(.orange)
                            }
                            if snapshot.upcomingScheduledCount > 0 {
                                Label(
                                    "\(snapshot.upcomingScheduledCount) scheduled in the next 30 days",
                                    systemImage: "calendar.badge.clock"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Recent") {
                        if snapshot.recentTransactions.isEmpty {
                            Text("No transactions yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(snapshot.recentTransactions) { transaction in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(transaction.note)
                                            .lineLimit(1)
                                            .privacySensitive()
                                        Spacer()
                                        Text(transaction.amount.formatted)
                                            .fontWeight(.semibold)
                                            .monospacedDigit()
                                            .privacySensitive()
                                    }
                                    Text(transaction.categoryPath ?? transaction.kind)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Open Pocket Ledger on your iPhone to sync your ledger.")
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .navigationTitle("Pocket Ledger")
        }
        .sheet(isPresented: $isShowingExpense) {
            NavigationStack {
                WatchExpenseView(store: store)
            }
        }
    }
}

private struct WatchPendingExpensesView: View {
    @ObservedObject var store: WatchLedgerStore

    private var failedExpenses: [WatchExpenseCommand] {
        store.pendingExpenses
            .filter { store.failedExpenseMessages[$0.id] != nil }
            .sorted { $0.date > $1.date }
    }

    private var waitingCount: Int {
        store.pendingExpenses.count - failedExpenses.count
    }

    var body: some View {
        List {
            if !failedExpenses.isEmpty {
                Section("Needs attention") {
                    ForEach(failedExpenses, id: \.id) { command in
                        NavigationLink {
                            WatchExpenseView(store: store, commandToCorrect: command)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(command.note.isEmpty ? "Expense" : command.note)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(command.amount.formatted)
                                        .monospacedDigit()
                                }
                                Text(store.failedExpenseMessages[command.id] ?? "Could not save this expense.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            if waitingCount > 0 {
                Section("Waiting to sync") {
                    Text("\(waitingCount) expense\(waitingCount == 1 ? "" : "s") will sync when the iPhone is available.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Queued expenses")
    }
}
