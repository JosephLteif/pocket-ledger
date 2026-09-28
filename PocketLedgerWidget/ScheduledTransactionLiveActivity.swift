import ActivityKit
import SwiftUI
import WidgetKit

struct ScheduledTransactionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduledTransactionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    context.state.totalItemsCount == 1
                        ? "Scheduled transaction"
                        : "Scheduled transactions",
                    systemImage: "calendar.badge.clock"
                )
                    .font(.subheadline.weight(.semibold))

                ForEach(context.state.items.prefix(2)) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "Scheduled transaction")
                                .font(.headline)
                                .lineLimit(1)
                                .privacySensitive()

                            if let amountText = item.amountText {
                                Text(amountText)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .privacySensitive()
                            }
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            countdown(to: item.dueDate)
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                            Text(item.dueDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }

                if context.state.totalItemsCount > 2 {
                    Text("And \(context.state.totalItemsCount - 2) more scheduled entries")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("Due entries are added when you next open Pocket Ledger.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(12)
            .activityBackgroundTint(Color(red: 0.08, green: 0.16, blue: 0.22))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let item = context.state.items.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title ?? "Scheduled transaction")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .privacySensitive()
                            if let amountText = item.amountText {
                                Text(amountText)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .privacySensitive()
                            }
                        }
                        .foregroundStyle(.white)
                    } else {
                        Label("Scheduled", systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.state.items.first?.dueDate ?? context.attributes.primaryDueDate)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(context.state.items.prefix(2)) { item in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title ?? "Scheduled transaction")
                                        .lineLimit(1)
                                        .privacySensitive()
                                    if let amountText = item.amountText {
                                        Text(amountText)
                                            .font(.caption2)
                                            .privacySensitive()
                                    }
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 2) {
                                    countdown(to: item.dueDate)
                                    Text(item.dueDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption2)
                                }
                            }
                            .font(.caption.monospacedDigit())
                        }
                        if context.state.totalItemsCount > 2 {
                            Text("+\(context.state.totalItemsCount - 2) more")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.teal)
            } compactTrailing: {
                countdown(to: context.state.items.first?.dueDate ?? context.attributes.primaryDueDate)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } minimal: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.teal)
            }
            .keylineTint(.teal)
        }
    }

    @ViewBuilder
    private func countdown(to dueDate: Date) -> some View {
        if dueDate > .now {
            Text(timerInterval: Date.now...dueDate, countsDown: true)
        } else {
            Text("Due now")
        }
    }
}
