import AppIntents
import SwiftUI
import WidgetKit

struct AddExpenseControl: ControlWidget {
    static let kind = "com.josephlteif.financedemo.add-expense"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            intent: QuickExpenseControlConfiguration.self
        ) { configuration in
            ControlWidgetButton(
                action: AddConfiguredExpenseIntent(amount: configuration.amount)
            ) {
                Label("Review \(configuration.amount) USD expense", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Add Pocket Ledger Expense")
        .description("Review and save a configured USD expense in Pocket Ledger.")
        .promptsForUserConfiguration()
    }
}
