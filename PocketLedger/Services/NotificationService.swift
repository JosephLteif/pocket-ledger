import Foundation
import UserNotifications
import Combine
import CryptoKit

struct ScheduledNotificationRecordRequest: Equatable, Identifiable, Sendable {
    let scheduleID: UUID
    let expectedNextRunDate: Date
    let expectedScheduleFingerprint: String

    var id: String {
        "\(scheduleID.uuidString)-\(expectedNextRunDate.timeIntervalSince1970)"
    }
}

@MainActor
final class ScheduledNotificationActionRouter: ObservableObject {
    static let shared = ScheduledNotificationActionRouter()

    @Published private(set) var pendingRequest: ScheduledNotificationRecordRequest?

    func enqueue(_ request: ScheduledNotificationRecordRequest) {
        pendingRequest = request
    }

    func consumePendingRequest() -> ScheduledNotificationRecordRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}

enum NotificationService {
    private static let scheduledPrefix = "pocket-ledger-scheduled-"
    private static let scheduledCategoryIdentifier = "pocket-ledger-scheduled-transaction"
    fileprivate static let recordScheduledActionIdentifier = "pocket-ledger-record-scheduled-now"
    private static let loanPrefix = "pocket-ledger-loan-"
    private static let budgetPrefix = "pocket-ledger-budget-"
    private static let dailyTransactionReminderIdentifier = "pocket-ledger-daily-transaction-reminder"
    private static let backupReminderIdentifier = "pocket-ledger-full-backup-reminder"
    private static let budgetAlertMonthKey = "pocketLedger.budgetAlertMonth"
    private static let budgetAlertSentKey = "pocketLedger.budgetAlertSent"
    static let globalReminderKey = "pocketLedger.scheduledReminderTiming"
    static let scheduledLiveActivityEnabledKey = "pocketLedger.scheduledLiveActivityEnabled"
    static let dailyTransactionReminderEnabledKey = "pocketLedger.dailyTransactionReminderEnabled"
    static let dailyTransactionReminderMinutesKey = "pocketLedger.dailyTransactionReminderMinutes"
    static let budgetThresholdAlertsEnabledKey = "pocketLedger.budgetThresholdAlertsEnabled"
    static let backupReminderEnabledKey = "pocketLedger.fullBackupReminderEnabled"
    static let lastFullBackupDateKey = "pocketLedger.lastFullBackupDate"
    static let dailyTransactionReminderDefaultMinutes = 20 * 60

    @MainActor
    static func configureForegroundPresentation() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ScheduledNotificationDelegate.shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: scheduledCategoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: recordScheduledActionIdentifier,
                        title: "Record now",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: []
            )
        ])
    }

    static var globalReminderTiming: ScheduledReminderTiming {
        ScheduledReminderTiming(
            rawValue: UserDefaults.standard.string(forKey: globalReminderKey) ?? ""
        ) ?? .oneDayBefore
    }

    static func scheduleFingerprint(_ schedule: ScheduledTransaction) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(schedule) else { return nil }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func setGlobalReminderTiming(_ timing: ScheduledReminderTiming) {
        UserDefaults.standard.set(timing.rawValue, forKey: globalReminderKey)
    }

    static func enableDailyTransactionReminder(minutesAfterMidnight: Int) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { throw DailyReminderError.permissionDenied }
        case .denied:
            throw DailyReminderError.permissionDenied
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            throw DailyReminderError.authorizationUnavailable
        }

        let minutes = min(max(minutesAfterMidnight, 0), 23 * 60 + 59)
        let content = UNMutableNotificationContent()
        content.title = "Time to log today’s transactions"
        content.body = "Take a moment to add today’s transactions to Pocket Ledger."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar.current
        dateComponents.hour = minutes / 60
        dateComponents.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )
        let request = UNNotificationRequest(
            identifier: dailyTransactionReminderIdentifier,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    static func disableDailyTransactionReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [dailyTransactionReminderIdentifier]
        )
    }

    static func enableFullBackupReminder(lastBackupAt: Date?) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                throw DailyReminderError.permissionDenied
            }
        case .denied:
            throw DailyReminderError.permissionDenied
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            throw DailyReminderError.authorizationUnavailable
        }
        try await scheduleFullBackupReminder(lastBackupAt: lastBackupAt)
    }

    static func refreshFullBackupReminderIfEnabled(lastBackupAt: Date?) async {
        guard UserDefaults.standard.bool(forKey: backupReminderEnabledKey) else { return }
        try? await scheduleFullBackupReminder(lastBackupAt: lastBackupAt)
    }

    static func disableFullBackupReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [backupReminderIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [backupReminderIdentifier])
        UserDefaults.standard.set(false, forKey: backupReminderEnabledKey)
    }

    private static func scheduleFullBackupReminder(lastBackupAt: Date?) async throws {
        let calendar = Calendar.current
        let baseline = lastBackupAt ?? .now
        var reminderDate = calendar.date(byAdding: .day, value: 90, to: baseline) ?? .now.addingTimeInterval(90 * 24 * 60 * 60)
        if reminderDate <= .now {
            reminderDate = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(24 * 60 * 60)
        }
        let content = UNMutableNotificationContent()
        content.title = "Time to back up Pocket Ledger"
        content.body = "Export a fresh full backup to keep a recoverable copy of your ledger."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminderDate),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: backupReminderIdentifier,
            content: content,
            trigger: trigger
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    static func enableBudgetThresholdAlerts() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                throw DailyReminderError.permissionDenied
            }
        case .denied:
            throw DailyReminderError.permissionDenied
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            throw DailyReminderError.authorizationUnavailable
        }
        UserDefaults.standard.set(true, forKey: budgetThresholdAlertsEnabledKey)
    }

    static func disableBudgetThresholdAlerts() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(
                withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(budgetPrefix) }
            )
        }
        UserDefaults.standard.set(false, forKey: budgetThresholdAlertsEnabledKey)
    }

    static func notifyBudgetThresholdCrossings(from oldData: FinanceData, to newData: FinanceData) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: budgetThresholdAlertsEnabledKey),
              oldData.transactions != newData.transactions,
              let month = Calendar.current.dateInterval(of: .month, for: .now) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }

        let monthKey = "\(Calendar.current.component(.year, from: month.start))-\(Calendar.current.component(.month, from: month.start))"
        var sent = defaults.string(forKey: budgetAlertMonthKey) == monthKey
            ? Set(defaults.stringArray(forKey: budgetAlertSentKey) ?? [])
            : []
        let oldIndex = LedgerIndex(data: oldData)
        let newIndex = LedgerIndex(data: newData)

        for budget in newData.budgets {
            guard oldData.budgets.contains(where: { $0.id == budget.id && $0 == budget }) else { continue }
            let allowance = financeBudgetAllowance(budget, in: newData, interval: month, using: newIndex).minorUnits
            guard allowance > 0 else { continue }
            let previousSpent = financeBudgetSpent(budget, in: oldData, interval: month, using: oldIndex).minorUnits
            let currentSpent = financeBudgetSpent(budget, in: newData, interval: month, using: newIndex).minorUnits

            for threshold in [80, 100] {
                let marker = "\(budget.id.uuidString)-\(threshold)"
                guard !sent.contains(marker),
                      Decimal(previousSpent) * 100 < Decimal(allowance) * Decimal(threshold),
                      Decimal(currentSpent) * 100 >= Decimal(allowance) * Decimal(threshold) else { continue }
                let content = UNMutableNotificationContent()
                content.title = threshold == 100 ? "Budget limit reached" : "Budget getting close"
                content.body = threshold == 100
                    ? "One of your budgets has reached its limit."
                    : "One of your budgets has used 80% of its limit."
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "pocket-ledger-budget-\(monthKey)-\(marker)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                do {
                    try await center.add(request)
                    sent.insert(marker)
                } catch {
                    continue
                }
            }
        }
        defaults.set(monthKey, forKey: budgetAlertMonthKey)
        defaults.set(Array(sent), forKey: budgetAlertSentKey)
    }

    static func requestScheduledTransactionNotifications(
        schedules: [ScheduledTransaction]
    ) async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    return "Notification permission was not granted."
                }
            } catch {
                return "Notification permission failed: \(error.localizedDescription)"
            }
        case .denied:
            return "Notifications are disabled for this app."
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return "Notification permission has an unknown status."
        }

        await refreshScheduledTransactionNotifications(schedules: schedules)
        return "Scheduled-entry reminders are enabled with a \(globalReminderTiming.title.lowercased()) default."
    }

    static func requestLoanNotifications(loans: [Loan]) async -> String {
        guard globalReminderTiming != .none else {
            await refreshLoanNotifications(loans: loans)
            return "Reminder timing is set to Never. Change the reminder timing in Settings to schedule loan reminders."
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return "Notification permission was not granted." }
            } catch {
                return "Notification permission failed: \(error.localizedDescription)"
            }
        case .denied:
            return "Notifications are disabled for this app."
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return "Notification permission is unavailable right now."
        }

        await refreshLoanNotifications(loans: loans)
        return "Loan reminders are enabled with a \(globalReminderTiming.title.lowercased()) default."
    }

    static func refreshLoanNotifications(loans: [Loan]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(loanPrefix) }
        )

        let loansByID = Dictionary(uniqueKeysWithValues: loans.map { ($0.id.uuidString, $0) })
        let delivered = await center.deliveredNotifications()
        let deliveredIDsToRemove = delivered.compactMap { notification -> String? in
            let identifier = notification.request.identifier
            guard identifier.hasPrefix(loanPrefix) else { return nil }
            guard let loanID = notification.request.content.userInfo["loanID"] as? String,
                  let loan = loansByID[loanID],
                  !loan.isSettled else {
                return identifier
            }
            guard let dueDate = loan.dueDate,
                  let deliveredDueDate = notification.request.content.userInfo["dueDate"] as? TimeInterval,
                  deliveredDueDate == dueDate.timeIntervalSince1970 else {
                return identifier
            }
            return nil
        }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDsToRemove)

        let calendar = Calendar.current
        let now = Date.now
        for loan in loans where !loan.isSettled {
            guard let dueDate = loan.dueDate else { continue }
            let timing = globalReminderTiming
            guard timing != .none else { continue }
            var dueComponents = calendar.dateComponents([.year, .month, .day], from: dueDate)
            dueComponents.hour = 9
            dueComponents.minute = 0
            guard let dueReminderDate = calendar.date(from: dueComponents) else { continue }
            let fireDate = timing == .atDue
                ? dueReminderDate
                : dueReminderDate.addingTimeInterval(-timing.leadTime)
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Pocket Ledger"
            content.body = "A loan payment is due soon. Open Pocket Ledger to review it."
            content.sound = .default
            content.userInfo = [
                "loanID": loan.id.uuidString,
                "dueDate": dueDate.timeIntervalSince1970
            ]
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: loanPrefix + loan.id.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            do {
                try await center.add(request)
            } catch {
                continue
            }
        }
    }

    static func refreshScheduledTransactionNotifications(
        schedules: [ScheduledTransaction]
    ) async {
        await ScheduledTransactionLiveActivityService.shared.refresh(
            schedules: schedules,
            isEnabled: UserDefaults.standard.bool(forKey: scheduledLiveActivityEnabledKey)
        )
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let existingIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(scheduledPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existingIDs)

        let calendar = Calendar.current
        let now = Date.now
        let schedulesByID = Dictionary(uniqueKeysWithValues: schedules.map { ($0.id.uuidString, $0) })
        let delivered = await center.deliveredNotifications()
        let deliveredIDsToRemove = delivered.compactMap { notification -> String? in
            let identifier = notification.request.identifier
            guard identifier.hasPrefix(scheduledPrefix) else { return nil }
            guard let scheduleID = notification.request.content.userInfo[
                "scheduledTransactionID"
            ] as? String,
                  let schedule = schedulesByID[scheduleID],
                  schedule.isEnabled else {
                return identifier
            }

            let timing = schedule.reminderTiming ?? globalReminderTiming
            guard timing != .none else { return identifier }
            let reminderDate = reminderDate(for: schedule, timing: timing)
            return reminderDate <= now || notification.date < reminderDate.addingTimeInterval(-60)
                ? identifier
                : nil
        }
        center.removeDeliveredNotifications(withIdentifiers: Array(Set(deliveredIDsToRemove)))

        for schedule in schedules where schedule.isEnabled && schedule.nextRunDate > now {
            let timing = schedule.reminderTiming ?? globalReminderTiming
            guard timing != .none else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Pocket Ledger"
            let title = schedule.note.isEmpty ? schedule.kind.displayName : schedule.note
            let dueDate = schedule.nextRunDate.formatted(date: .abbreviated, time: .shortened)
            content.body = "\(title) is scheduled for \(dueDate)."
            content.sound = .default
            content.categoryIdentifier = scheduledCategoryIdentifier
            var userInfo: [String: Any] = [
                "scheduledTransactionID": schedule.id.uuidString,
                "expectedNextRunDate": schedule.nextRunDate.timeIntervalSince1970
            ]
            if let fingerprint = scheduleFingerprint(schedule) {
                userInfo["expectedScheduleFingerprint"] = fingerprint
            }
            content.userInfo = userInfo

            let reminderDate = reminderDate(for: schedule, timing: timing)
            // A refresh after delivery must not turn an elapsed reminder into a new alert.
            guard reminderDate > now else { continue }

            let trigger: UNNotificationTrigger
            if reminderDate.timeIntervalSince(now) > 1 {
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: reminderDate
                )
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
            } else {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            }
            let request = UNNotificationRequest(
                identifier: scheduledPrefix + schedule.id.uuidString,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
            } catch { continue }
        }
    }

    private static func reminderDate(
        for schedule: ScheduledTransaction,
        timing: ScheduledReminderTiming
    ) -> Date {
        timing == .atDue
            ? schedule.nextRunDate
            : schedule.nextRunDate.addingTimeInterval(-timing.leadTime)
    }

    private enum DailyReminderError: LocalizedError {
        case permissionDenied
        case authorizationUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Allow notifications for Pocket Ledger in iPhone Settings to enable this reminder."
            case .authorizationUnavailable:
                return "Notification permission is unavailable right now."
            }
        }
    }
}

private final class ScheduledNotificationDelegate:
    NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    static let shared = ScheduledNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == NotificationService.recordScheduledActionIdentifier,
              let scheduleID = response.notification.request.content.userInfo[
                  "scheduledTransactionID"
              ] as? String,
              let id = UUID(uuidString: scheduleID),
              let expectedTimestamp = response.notification.request.content.userInfo[
                  "expectedNextRunDate"
              ] as? NSNumber,
              let expectedFingerprint = response.notification.request.content.userInfo[
                  "expectedScheduleFingerprint"
              ] as? String else {
            return
        }
        let request = ScheduledNotificationRecordRequest(
            scheduleID: id,
            expectedNextRunDate: Date(timeIntervalSince1970: expectedTimestamp.doubleValue),
            expectedScheduleFingerprint: expectedFingerprint
        )
        await ScheduledNotificationActionRouter.shared.enqueue(request)
    }
}
