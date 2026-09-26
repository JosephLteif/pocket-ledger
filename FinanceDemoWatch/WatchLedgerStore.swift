import Foundation
import SwiftUI
import WatchConnectivity
import WidgetKit

enum WatchSyncStatus: Equatable {
    case unavailable
    case connecting
    case synced
    case queued
    case error

    var title: String {
        switch self {
        case .unavailable:
            return "Watch sync unavailable"
        case .connecting:
            return "Connecting to iPhone"
        case .synced:
            return "Synced"
        case .queued:
            return "Waiting to sync"
        case .error:
            return "Sync needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .unavailable:
            return "iphone.slash"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .synced:
            return "checkmark.circle.fill"
        case .queued:
            return "clock"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class WatchLedgerStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: WatchLedgerSnapshot?
    @Published private(set) var pendingExpenses: [WatchExpenseCommand]
    @Published private(set) var failedExpenseMessages: [UUID: String]
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var status: WatchSyncStatus
    @Published private(set) var errorMessage: String?

    private let cacheStore: WatchLedgerCacheStore
    private let session: WCSession

    override init() {
        cacheStore = WatchLedgerCacheStore()
        session = WCSession.default

        let cache = cacheStore.load()
        snapshot = cache.snapshot
        pendingExpenses = cache.pendingExpenses
        failedExpenseMessages = cache.failedExpenseMessages
        lastSyncedAt = cache.lastSyncDate
        status = WCSession.isSupported()
            ? (!cache.failedExpenseMessages.isEmpty ? .error : cache.pendingExpenses.isEmpty ? .connecting : .queued)
            : .unavailable
        errorMessage = cache.failedExpenseMessages.values.first ?? cache.lastError
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            status = .unavailable
            return
        }

        session.delegate = self
        status = .connecting
        session.activate()
    }

    func queueExpense(
        amount: Money,
        accountID: UUID,
        categoryID: UUID?,
        note: String
    ) {
        let command = WatchExpenseCommand(
            amount: amount,
            accountID: accountID,
            categoryID: categoryID,
            note: note
        )
        pendingExpenses.append(command)
        errorMessage = nil
        status = .queued
        saveCache()
        sendPendingExpenses()
    }

    func correctAndRetryExpense(
        id: UUID,
        amount: Money,
        accountID: UUID,
        categoryID: UUID?,
        note: String
    ) {
        guard let recovered = WatchExpenseQueuePolicy.correctAndRetryFailedExpense(
            id: id,
            amount: amount,
            accountID: accountID,
            categoryID: categoryID,
            note: note,
            commands: pendingExpenses,
            failures: failedExpenseMessages
        ) else { return }
        pendingExpenses = recovered.commands
        failedExpenseMessages = recovered.failures
        updateStatusAfterRecoveryAction()
        saveCache()
        sendPendingExpenses()
    }

    func retryFailedExpense(id: UUID) {
        guard let recovered = WatchExpenseQueuePolicy.retryFailedExpense(
            id: id,
            commands: pendingExpenses,
            failures: failedExpenseMessages
        ) else { return }
        pendingExpenses = recovered.commands
        failedExpenseMessages = recovered.failures
        updateStatusAfterRecoveryAction()
        saveCache()
        sendPendingExpenses()
    }

    func discardFailedExpense(id: UUID) {
        guard let recovered = WatchExpenseQueuePolicy.discardFailedExpense(
            id: id,
            commands: pendingExpenses,
            failures: failedExpenseMessages
        ) else { return }
        pendingExpenses = recovered.commands
        failedExpenseMessages = recovered.failures
        updateStatusAfterRecoveryAction()
        saveCache()
    }

    private func sendPendingExpenses() {
        guard session.activationState == .activated else { return }

        for expense in WatchExpenseQueuePolicy.commandsReadyToSend(
            pendingExpenses,
            rejectedIDs: Set(failedExpenseMessages.keys)
        ) {
            guard let context = WatchSyncCodec.dictionary(for: expense) else { continue }
            session.transferUserInfo(context)
        }
    }

    private func handleActivation(isActivated: Bool, errorMessage: String?) {
        if let errorMessage {
            status = .error
            self.errorMessage = errorMessage
            saveCache()
            return
        }

        guard isActivated else {
            status = .connecting
            return
        }

        self.errorMessage = failedExpenseMessages.values.first
        status = !failedExpenseMessages.isEmpty ? .error : pendingExpenses.isEmpty ? .synced : .queued
        sendPendingExpenses()
        saveCache()
    }

    private func apply(_ snapshot: WatchLedgerSnapshot) {
        self.snapshot = snapshot
        lastSyncedAt = Date()
        errorMessage = nil

        let receivedTransactionIDs = Set(snapshot.recentTransactions.map(\.id))
        pendingExpenses.removeAll { receivedTransactionIDs.contains($0.id) }
        failedExpenseMessages = failedExpenseMessages.filter { !receivedTransactionIDs.contains($0.key) }
        errorMessage = failedExpenseMessages.values.first
        status = !failedExpenseMessages.isEmpty ? .error : pendingExpenses.isEmpty ? .synced : .queued
        saveCache()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func handle(_ acknowledgement: WatchExpenseAcknowledgement) {
        guard pendingExpenses.contains(where: { $0.id == acknowledgement.commandID }) else {
            return
        }

        if acknowledgement.accepted {
            pendingExpenses.removeAll { $0.id == acknowledgement.commandID }
            failedExpenseMessages.removeValue(forKey: acknowledgement.commandID)
            errorMessage = failedExpenseMessages.values.first
            status = !failedExpenseMessages.isEmpty ? .error : pendingExpenses.isEmpty ? .synced : .queued
        } else {
            failedExpenseMessages[acknowledgement.commandID] = acknowledgement.message
            status = .error
            errorMessage = acknowledgement.message
        }
        saveCache()
    }

    private func saveCache() {
        cacheStore.save(
            WatchLedgerCache(
                snapshot: snapshot,
                pendingExpenses: pendingExpenses,
                lastSyncDate: lastSyncedAt,
                lastError: errorMessage,
                failedExpenseMessages: failedExpenseMessages
            )
        )
    }

    private func updateStatusAfterRecoveryAction() {
        errorMessage = failedExpenseMessages.values.first
        status = !failedExpenseMessages.isEmpty ? .error : pendingExpenses.isEmpty ? .synced : .queued
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isActivated = activationState == .activated
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleActivation(isActivated: isActivated, errorMessage: message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let snapshot = WatchSyncCodec.snapshot(from: applicationContext) else { return }
        Task { @MainActor [weak self] in
            self?.apply(snapshot)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let snapshot = WatchSyncCodec.snapshot(from: userInfo) {
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
        if let acknowledgement = WatchSyncCodec.acknowledgement(from: userInfo) {
            Task { @MainActor [weak self] in
                self?.handle(acknowledgement)
            }
        }
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activate()
        }
    }
#endif
}
