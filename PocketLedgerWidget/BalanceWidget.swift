import SwiftUI
import WidgetKit

private enum PocketWidgetTheme {
    static let background = Color(red: 0.106, green: 0.090, blue: 0.078)
    static let accent = Color(red: 0.894, green: 0.604, blue: 0.471)
    static let income = Color(red: 0.525, green: 0.722, blue: 1.000)
    static let warning = Color(red: 1.000, green: 0.816, blue: 0.475)
}

struct BalanceEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: FinanceWidgetSnapshot
}

struct BalanceTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(
            date: .now,
            snapshot: FinanceWidgetSnapshot(
                usdAvailable: Money(currency: .usd, minorUnits: 0),
                lbpAvailable: Money(currency: .lbp, minorUnits: 0),
                eurAvailable: Money(currency: .eur, minorUnits: 0),
                latestTransactionDescription: "No transactions yet",
                lastUpdated: .now,
                appGroupAvailable: true,
                attentionCount: 0,
                upcomingScheduledCount: 0
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(
            BalanceEntry(
                date: .now,
                snapshot: FinanceStorage(context: "widget").widgetSnapshot()
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let entry = BalanceEntry(
            date: .now,
            snapshot: FinanceStorage(context: "widget").widgetSnapshot()
        )
        let refreshDate = Date(timeIntervalSinceNow: 15 * 60)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

struct BalanceWidgetEntryView: View {
    let entry: BalanceEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Pocket Ledger")
                .font(.caption)
                .foregroundStyle(PocketWidgetTheme.accent)

            if entry.snapshot.appGroupAvailable {
                if family == .systemSmall {
                    balanceRow(currency: "USD", amount: entry.snapshot.usdAvailable.formatted)
                    balanceRow(currency: "LBP", amount: entry.snapshot.lbpAvailable.formatted)
                    balanceRow(currency: "EUR", amount: entry.snapshot.eurAvailable.formatted)
                } else {
                    balanceRow(currency: "USD", amount: entry.snapshot.usdAvailable.formatted)
                    balanceRow(currency: "LBP", amount: entry.snapshot.lbpAvailable.formatted)
                    balanceRow(currency: "EUR", amount: entry.snapshot.eurAvailable.formatted)

                    Text(entry.snapshot.latestTransactionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()

                    if entry.snapshot.attentionCount > 0 || entry.snapshot.upcomingScheduledCount > 0 {
                        HStack(spacing: 6) {
                            if entry.snapshot.attentionCount > 0 {
                                Label(
                                    "\(entry.snapshot.attentionCount) attention",
                                    systemImage: "exclamationmark.circle"
                                )
                                .foregroundStyle(PocketWidgetTheme.warning)
                            }
                            if entry.snapshot.upcomingScheduledCount > 0 {
                                Label(
                                    "\(entry.snapshot.upcomingScheduledCount) upcoming",
                                    systemImage: "calendar.badge.clock"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
            } else {
                Text("Shared storage unavailable")
                    .font(.headline)
                    .foregroundStyle(PocketWidgetTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Open Pocket Ledger to refresh shared data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                if entry.snapshot.appGroupAvailable {
                    Text(entry.snapshot.lastUpdated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Open app to refresh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if entry.snapshot.appGroupAvailable {
                    if family == .systemMedium {
                        Link(destination: URL(string: "pocketledger://add/expense?amount=5&currency=USD&note=Quick%20widget%20expense")!) {
                            Label("Review $5 expense", systemImage: "plus.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PocketWidgetTheme.accent)
                        }
                        .accessibilityLabel("Review a five dollar USD expense in Pocket Ledger")
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PocketWidgetTheme.warning)
                        .accessibilityLabel("Open Pocket Ledger to refresh shared data")
                }
            }
        }
        .containerBackground(PocketWidgetTheme.background, for: .widget)
        .widgetURL(URL(string: family == .systemSmall
            ? "pocketledger://overview"
            : "pocketledger://transactions"))
    }

    private func balanceRow(currency: String, amount: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(currency)
                .font(.caption.weight(.semibold))
                .foregroundStyle(currency == "USD" ? PocketWidgetTheme.income : .secondary)
            Spacer(minLength: 6)
            Text(amount)
                .font((family == .systemSmall ? Font.body : Font.title3).weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.80)
                .lineLimit(1)
                .privacySensitive()
        }
    }
}

struct BalanceWidget: Widget {
    static let kind = "BalanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: BalanceTimelineProvider()) { entry in
            BalanceWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pocket Ledger Balances")
        .description("Shows USD, LBP, and EUR balances and opens a prefilled expense for review.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BalanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
        ScheduledTransactionLiveActivity()
        AddExpenseControl()
    }
}
