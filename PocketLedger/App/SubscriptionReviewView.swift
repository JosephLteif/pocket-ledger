import SwiftUI

@MainActor
struct SubscriptionReviewView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @State private var editingSchedule: ScheduledTransaction?
    @State private var isPresentingEditor = false

    private var recurringExpenses: [ScheduledTransaction] {
        store.data.scheduledTransactions
            .filter { $0.isEnabled && $0.frequency != .once && $0.kind == .expense }
            .sorted { $0.nextRunDate < $1.nextRunDate }
    }

    private var annualTotals: [LedgerCurrency: Decimal] {
        var totals: [LedgerCurrency: Decimal] = [:]
        for schedule in recurringExpenses {
            let annualMultiplier: Decimal
            switch schedule.frequency {
            case .once:
                continue
            case .daily:
                annualMultiplier = 365
            case .weekly:
                annualMultiplier = 52
            case .monthly:
                annualMultiplier = 12
            case .yearly:
                annualMultiplier = 1
            }
            for charge in chargeAmounts(for: schedule) {
                totals[charge.currency, default: .zero] += Decimal(charge.minorUnits) * annualMultiplier
            }
        }
        return totals
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Review recurring charges and their estimated yearly cost.")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)

                if recurringExpenses.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.title2)
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                        Text("No recurring expenses yet").font(.headline)
                        Text("Add a recurring expense in Scheduled to include it here.")
                            .font(.subheadline)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        NavigationLink {
                            ScheduledTransactionsView(store: store)
                        } label: {
                            Text("Open Scheduled")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PocketLedgerTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                    .padding(.horizontal, 20)
                    .pocketGroupedSurface(cornerRadius: 20)
                } else {
                    if !annualTotals.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Estimated yearly cost")
                                .font(.headline)
                            ForEach(LedgerCurrency.allCases.filter { annualTotals[$0] != nil }) { currency in
                                LabeledContent(
                                    currency.rawValue,
                                    value: formatted(annualTotals[currency] ?? .zero, currency: currency)
                                )
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                        }
                        .padding(16)
                        .pocketGroupedSurface(cornerRadius: 20)
                    }

                    ForEach(recurringExpenses) { schedule in
                        subscriptionCard(schedule)
                    }

                    Text("Yearly estimates use each schedule’s frequency. Price changes are matched by exact transaction name and currency.")
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .pocketScreen()
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ScheduledTransactionsView(store: store)
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("Manage scheduled transactions")
                }
            }
        }
        .sheet(isPresented: $isPresentingEditor, onDismiss: { editingSchedule = nil }) {
            TransactionEditor(
                store: store,
                initialTiming: .scheduled,
                scheduledTransaction: editingSchedule
            )
        }
    }

    private func subscriptionCard(_ schedule: ScheduledTransaction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(schedule.note)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(schedule.frequency.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }

            if let category = store.data.categories.first(where: { $0.id == schedule.categoryID }) {
                Text(category.name)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }

            ForEach(chargeAmounts(for: schedule), id: \.currency) { charge in
                HStack {
                    Text("\(charge.formatted) per charge")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(PocketLedgerTheme.textPrimary)
                    Spacer()
                    Text("\(schedule.nextRunDate.formatted(date: .abbreviated, time: .omitted)) next")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }

                if let change = priceChange(for: schedule, currency: charge.currency) {
                    Label("Changed from \(change.previous.formatted) to \(change.current.formatted)", systemImage: "arrow.left.arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketLedgerTheme.warning)
                }
            }

            HStack {
                Spacer()
                Button("Review schedule") {
                    editingSchedule = schedule
                    isPresentingEditor = true
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 20)
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(PocketLedgerTheme.divider, lineWidth: 1) }
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
}
