import Foundation
import WatchConnectivity

extension Notification.Name {
    static let pocketLedgerWatchLedgerDidChange = Notification.Name(
        "PocketLedger.watchLedgerDidChange"
    )
}

final class WatchConnectivityService: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConnectivityService()

    private let session = WCSession.default

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated else { return }
        publishCurrentData()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = WatchSyncCodec.expenseCommand(from: userInfo) else { return }
        process(command)
    }

    private func publishCurrentData() {
        let storage = FinanceStorage(context: "watch-sync")
        guard storage.isPersistent else { return }
        let data = storage.load()
        guard !storage.isCorrupted else { return }
        WatchSyncPublisher.publish(data: data)
    }

    private func process(_ command: WatchExpenseCommand) {
        let storage = FinanceStorage(context: "watch-sync")
        guard storage.isPersistent else {
            sendAcknowledgement(
                for: command,
                accepted: false,
                message: "Pocket Ledger storage is unavailable."
            )
            return
        }

        var data = storage.load()
        guard !storage.isCorrupted else {
            sendAcknowledgement(
                for: command,
                accepted: false,
                message: "Pocket Ledger data could not be read."
            )
            return
        }

        if WatchExpenseQueuePolicy.wasAlreadyRecorded(commandID: command.id, in: data.transactions) {
            sendAcknowledgement(
                for: command,
                accepted: true,
                message: "Expense was already saved."
            )
            return
        }

        let trimmedNote = command.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let transaction = LedgerTransaction(
            id: command.id,
            date: command.date,
            note: trimmedNote.isEmpty ? TransactionKind.expense.displayName : trimmedNote,
            kind: .expense,
            categoryID: command.categoryID,
            outflows: [
                MoneyMovement(accountID: command.accountID, money: command.amount)
            ],
            inflows: []
        )

        guard FinanceTransactionValidator.validate(transaction, in: data) == nil else {
            sendAcknowledgement(
                for: command,
                accepted: false,
                message: "The selected account or category is no longer available."
            )
            return
        }

        guard storage.appendTransaction(transaction) else {
            sendAcknowledgement(
                for: command,
                accepted: false,
                message: "The expense could not be saved."
            )
            return
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .pocketLedgerWatchLedgerDidChange,
                object: nil
            )
        }
        sendAcknowledgement(
            for: command,
            accepted: true,
            message: "Expense saved to Pocket Ledger."
        )
    }

    private func sendAcknowledgement(
        for command: WatchExpenseCommand,
        accepted: Bool,
        message: String
    ) {
        guard session.activationState == .activated,
              let context = WatchSyncCodec.dictionary(
                for: WatchExpenseAcknowledgement(
                    commandID: command.id,
                    accepted: accepted,
                    message: message
                )
              ) else {
            return
        }

        session.transferUserInfo(context)
    }
}
