import ActivityKit
import Foundation

struct ScheduledTransactionActivityItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let dueDate: Date
    let title: String?
    let amountText: String?
}

struct ScheduledTransactionActivityAttributes: ActivityAttributes {
    let primaryScheduleID: UUID
    let primaryDueDate: Date
    let startDate: Date

    struct ContentState: Codable, Hashable, Sendable {
        let items: [ScheduledTransactionActivityItem]
        let additionalItemsCount: Int

        var totalItemsCount: Int {
            items.count + additionalItemsCount
        }
    }
}
