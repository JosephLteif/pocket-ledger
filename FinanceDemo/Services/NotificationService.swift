import Foundation
import UserNotifications

enum NotificationService {
    private static let scheduledPrefix = "pocket-ledger-scheduled-"
    private static let loanPrefix = "pocket-ledger-loan-"
    private static let dailyTransactionReminderIdentifier = "pocket-ledger-daily-transaction-reminder"
    static let globalReminderKey = "pocketLedger.scheduledReminderTiming"
    static let scheduledLiveActivityEnabledKey = "pocketLedger.scheduledLiveActivityEnabled"
    static let dailyTransactionReminderEnabledKey = "pocketLedger.dailyTransactionReminderEnabled"
    static let dailyTransactionReminderMinutesKey = "pocketLedger.dailyTransactionReminderMinutes"
    static let dailyTransactionReminderDefaultMinutes = 20 * 60

    @MainActor
    static func configureForegroundPresentation() {
        UNUserNotificationCenter.current().delegate = ScheduledNotificationDelegate.shared
    }

    static var globalReminderTiming: ScheduledReminderTiming {
        ScheduledReminderTiming(
            rawValue: UserDefaults.standard.string(forKey: globalReminderKey) ?? ""
        ) ?? .oneDayBefore
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

    static func scheduleDemoNotification() async -> String {
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

        let content = UNMutableNotificationContent()
        content.title = "Pocket Ledger"
        content.body = "Pocket Ledger notification works."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(
            identifier: "finance-demo-test-notification",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            return "Notification scheduled for about 10 seconds from now."
        } catch {
            return "Notification scheduling failed: \(error.localizedDescription)"
        }
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
            content.userInfo = ["scheduledTransactionID": schedule.id.uuidString]

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
}
