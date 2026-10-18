import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

struct ScheduledTransactionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduledTransactionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                Label("Scheduled", systemImage: "calendar.badge.clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ScheduledTransactionActivityTheme.accent)

                ForEach(context.state.items.prefix(2)) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "Scheduled transaction")
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .privacySensitive()

                            if let amountText = item.amountText {
                                Text(amountText)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .foregroundStyle(.secondary)
                                    .privacySensitive()
                            }
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .trailing, spacing: 2) {
                            countdown(to: item.dueDate)
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(item.dueDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if context.state.totalItemsCount > 2 {
                    Text("+\(context.state.totalItemsCount - 2) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Text("Added when you open Pocket Ledger.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.primary)
            .padding(12)
            .activityBackgroundTint(ScheduledTransactionActivityTheme.surface)
            .activitySystemActionForegroundColor(ScheduledTransactionActivityTheme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let item = context.state.items.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title ?? "Scheduled transaction")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .privacySensitive()
                            if let amountText = item.amountText {
                                Text(amountText)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let dueDate = context.state.items.first?.dueDate ?? context.attributes.primaryDueDate
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                        Text(dueDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if context.state.totalItemsCount > 1 {
                            Text("+\(context.state.totalItemsCount - 1) more")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                }
            } compactLeading: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ScheduledTransactionActivityTheme.accent)
            } compactTrailing: {
                countdown(to: context.state.items.first?.dueDate ?? context.attributes.primaryDueDate)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ScheduledTransactionActivityTheme.accent)
            }
            .keylineTint(ScheduledTransactionActivityTheme.accent)
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

private enum ScheduledTransactionActivityTheme {
    static let surface = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.161, green: 0.129, blue: 0.110, alpha: 1)
        } else {
            return UIColor(red: 1, green: 0.984, blue: 0.965, alpha: 1)
        }
    })

    static let accent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.894, green: 0.604, blue: 0.471, alpha: 1)
        } else {
            return UIColor(red: 0.639, green: 0.329, blue: 0.220, alpha: 1)
        }
    })
}
