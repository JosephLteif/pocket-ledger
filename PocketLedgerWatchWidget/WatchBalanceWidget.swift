import SwiftUI
import WidgetKit

struct WatchBalanceEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchLedgerSnapshot?
}

struct WatchBalanceProvider: TimelineProvider {
    private var placeholderSnapshot: WatchLedgerSnapshot {
        WatchLedgerSnapshot(
            version: WatchLedgerSnapshot.currentVersion,
            generatedAt: .now,
            balances: [
                WatchBalanceSummary(
                    currency: .usd,
                    balance: Money(currency: .usd, minorUnits: 125000)
                )
            ],
            accounts: [],
            categories: [],
            recentTransactions: []
        )
    }

    func placeholder(in context: Context) -> WatchBalanceEntry {
        WatchBalanceEntry(date: .now, snapshot: placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchBalanceEntry) -> Void) {
        completion(
            WatchBalanceEntry(
                date: .now,
                snapshot: WatchLedgerCacheStore().load().snapshot ?? placeholderSnapshot
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchBalanceEntry>) -> Void) {
        let entry = WatchBalanceEntry(
            date: .now,
            snapshot: WatchLedgerCacheStore().load().snapshot
        )
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 30, to: .now)
            ?? Date(timeIntervalSinceNow: 1_800)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

struct WatchBalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchLedgerSnapshot?

    private var usdBalance: Money? {
        snapshot?.balances.first { $0.currency == .usd }?.balance
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Text(usdBalance?.compactFormatted() ?? "—")
                .font(.caption.weight(.semibold).monospacedDigit())
                .privacySensitive()
        case .accessoryInline:
            Text("Pocket Ledger: \(usdBalance?.compactFormatted() ?? "—")")
                .font(.caption)
                .privacySensitive()
        default:
            VStack(alignment: .leading) {
                Text("Pocket Ledger")
                    .font(.caption2)
                Text(usdBalance?.formatted ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .privacySensitive()
            }
        }
    }
}

struct WatchBalanceWidget: Widget {
    let kind = "WatchBalanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchBalanceProvider()) { entry in
            WatchBalanceWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Pocket Ledger")
        .description("See your available USD balance.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main
struct PocketLedgerWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchBalanceWidget()
    }
}
