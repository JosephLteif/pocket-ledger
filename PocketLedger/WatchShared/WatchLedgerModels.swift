import Foundation

enum WatchLedgerConstants {
    static let appGroupIdentifier = "group.com.josephlteif.financedemo"
    static let cacheKey = "watchLedgerCache"
    static let snapshotKey = "snapshot"
    static let expenseCommandKey = "expenseCommand"
    static let acknowledgementKey = "acknowledgement"
}

struct WatchBalanceSummary: Identifiable, Codable, Equatable, Sendable {
    let currency: LedgerCurrency
    let balance: Money

    var id: String { currency.rawValue }
}

struct WatchAccountSummary: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let currency: LedgerCurrency
    let balance: Money
    let canUseForExpense: Bool
}

struct WatchCategorySummary: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let path: String
}

struct WatchTransactionSummary: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let note: String
    let kind: String
    let amount: Money
    let accountName: String
    let categoryPath: String?
}

struct WatchLedgerSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let generatedAt: Date
    let balances: [WatchBalanceSummary]
    let accounts: [WatchAccountSummary]
    let categories: [WatchCategorySummary]
    let recentTransactions: [WatchTransactionSummary]
    let attentionCount: Int
    let upcomingScheduledCount: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case generatedAt
        case balances
        case accounts
        case categories
        case recentTransactions
        case attentionCount
        case upcomingScheduledCount
    }

    init(
        version: Int,
        generatedAt: Date,
        balances: [WatchBalanceSummary],
        accounts: [WatchAccountSummary],
        categories: [WatchCategorySummary],
        recentTransactions: [WatchTransactionSummary],
        attentionCount: Int = 0,
        upcomingScheduledCount: Int = 0
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.balances = balances
        self.accounts = accounts
        self.categories = categories
        self.recentTransactions = recentTransactions
        self.attentionCount = attentionCount
        self.upcomingScheduledCount = upcomingScheduledCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        balances = try container.decode([WatchBalanceSummary].self, forKey: .balances)
        accounts = try container.decode([WatchAccountSummary].self, forKey: .accounts)
        categories = try container.decode([WatchCategorySummary].self, forKey: .categories)
        recentTransactions = try container.decode(
            [WatchTransactionSummary].self,
            forKey: .recentTransactions
        )
        attentionCount = try container.decodeIfPresent(Int.self, forKey: .attentionCount) ?? 0
        upcomingScheduledCount = try container.decodeIfPresent(
            Int.self,
            forKey: .upcomingScheduledCount
        ) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(balances, forKey: .balances)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(categories, forKey: .categories)
        try container.encode(recentTransactions, forKey: .recentTransactions)
        try container.encode(attentionCount, forKey: .attentionCount)
        try container.encode(upcomingScheduledCount, forKey: .upcomingScheduledCount)
    }
}

struct WatchExpenseCommand: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let date: Date
    let amount: Money
    let accountID: UUID
    let categoryID: UUID?
    let note: String

    init(
        id: UUID = UUID(),
        date: Date = .now,
        amount: Money,
        accountID: UUID,
        categoryID: UUID?,
        note: String
    ) {
        version = Self.currentVersion
        self.id = id
        self.date = date
        self.amount = amount
        self.accountID = accountID
        self.categoryID = categoryID
        self.note = note
    }

    func corrected(
        amount: Money,
        accountID: UUID,
        categoryID: UUID?,
        note: String
    ) -> WatchExpenseCommand {
        WatchExpenseCommand(
            id: id,
            date: date,
            amount: amount,
            accountID: accountID,
            categoryID: categoryID,
            note: note
        )
    }
}

enum WatchExpenseQueuePolicy {
    static func wasAlreadyRecorded(commandID: UUID, in transactions: [LedgerTransaction]) -> Bool {
        transactions.contains { $0.id == commandID }
    }

    static func commandsReadyToSend(
        _ commands: [WatchExpenseCommand],
        rejectedIDs: Set<UUID>
    ) -> [WatchExpenseCommand] {
        var sentIDs: Set<UUID> = []
        return commands.filter {
            !rejectedIDs.contains($0.id) && sentIDs.insert($0.id).inserted
        }
    }

    static func retryFailedExpense(
        id: UUID,
        commands: [WatchExpenseCommand],
        failures: [UUID: String]
    ) -> WatchExpenseQueueState? {
        guard commands.contains(where: { $0.id == id }), failures[id] != nil else { return nil }
        var updatedFailures = failures
        updatedFailures.removeValue(forKey: id)
        return WatchExpenseQueueState(commands: commands, failures: updatedFailures)
    }

    static func correctAndRetryFailedExpense(
        id: UUID,
        amount: Money,
        accountID: UUID,
        categoryID: UUID?,
        note: String,
        commands: [WatchExpenseCommand],
        failures: [UUID: String]
    ) -> WatchExpenseQueueState? {
        guard let index = commands.firstIndex(where: { $0.id == id }), failures[id] != nil else {
            return nil
        }
        var updatedCommands = commands
        updatedCommands[index] = commands[index].corrected(
            amount: amount,
            accountID: accountID,
            categoryID: categoryID,
            note: note
        )
        var updatedFailures = failures
        updatedFailures.removeValue(forKey: id)
        return WatchExpenseQueueState(commands: updatedCommands, failures: updatedFailures)
    }

    static func discardFailedExpense(
        id: UUID,
        commands: [WatchExpenseCommand],
        failures: [UUID: String]
    ) -> WatchExpenseQueueState? {
        guard failures[id] != nil else { return nil }
        var updatedFailures = failures
        updatedFailures.removeValue(forKey: id)
        return WatchExpenseQueueState(
            commands: commands.filter { $0.id != id },
            failures: updatedFailures
        )
    }
}

struct WatchExpenseQueueState: Equatable {
    let commands: [WatchExpenseCommand]
    let failures: [UUID: String]
}

struct WatchExpenseAcknowledgement: Codable, Equatable, Sendable {
    let commandID: UUID
    let accepted: Bool
    let message: String
}

struct WatchLedgerCache: Codable, Equatable {
    var snapshot: WatchLedgerSnapshot?
    var pendingExpenses: [WatchExpenseCommand]
    var lastSyncDate: Date?
    var lastError: String?
    var failedExpenseMessages: [UUID: String]

    init(
        snapshot: WatchLedgerSnapshot?,
        pendingExpenses: [WatchExpenseCommand],
        lastSyncDate: Date?,
        lastError: String?,
        failedExpenseMessages: [UUID: String] = [:]
    ) {
        self.snapshot = snapshot
        self.pendingExpenses = pendingExpenses
        self.lastSyncDate = lastSyncDate
        self.lastError = lastError
        self.failedExpenseMessages = failedExpenseMessages
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case pendingExpenses
        case lastSyncDate
        case lastError
        case failedExpenseMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decodeIfPresent(WatchLedgerSnapshot.self, forKey: .snapshot)
        pendingExpenses = try container.decodeIfPresent([WatchExpenseCommand].self, forKey: .pendingExpenses) ?? []
        lastSyncDate = try container.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        failedExpenseMessages = try container.decodeIfPresent([UUID: String].self, forKey: .failedExpenseMessages) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
        try container.encode(pendingExpenses, forKey: .pendingExpenses)
        try container.encodeIfPresent(lastSyncDate, forKey: .lastSyncDate)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(failedExpenseMessages, forKey: .failedExpenseMessages)
    }

    static let empty = WatchLedgerCache(
        snapshot: nil,
        pendingExpenses: [],
        lastSyncDate: nil,
        lastError: nil
    )
}

enum WatchSyncCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func dictionary(for snapshot: WatchLedgerSnapshot) -> [String: Any]? {
        guard let data = try? makeEncoder().encode(snapshot) else { return nil }
        return [WatchLedgerConstants.snapshotKey: data]
    }

    static func dictionary(for command: WatchExpenseCommand) -> [String: Any]? {
        guard let data = try? makeEncoder().encode(command) else { return nil }
        return [WatchLedgerConstants.expenseCommandKey: data]
    }

    static func dictionary(for acknowledgement: WatchExpenseAcknowledgement) -> [String: Any]? {
        guard let data = try? makeEncoder().encode(acknowledgement) else { return nil }
        return [WatchLedgerConstants.acknowledgementKey: data]
    }

    static func snapshot(from context: [String: Any]) -> WatchLedgerSnapshot? {
        decode(WatchLedgerSnapshot.self, from: context[WatchLedgerConstants.snapshotKey])
    }

    static func expenseCommand(from context: [String: Any]) -> WatchExpenseCommand? {
        decode(WatchExpenseCommand.self, from: context[WatchLedgerConstants.expenseCommandKey])
    }

    static func acknowledgement(from context: [String: Any]) -> WatchExpenseAcknowledgement? {
        decode(WatchExpenseAcknowledgement.self, from: context[WatchLedgerConstants.acknowledgementKey])
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from value: Any?) -> Value? {
        guard let data = value as? Data else { return nil }
        return try? makeDecoder().decode(type, from: data)
    }
}

final class WatchLedgerCacheStore {
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: WatchLedgerConstants.appGroupIdentifier) ?? .standard
    }

    func load() -> WatchLedgerCache {
        guard let data = defaults.data(forKey: WatchLedgerConstants.cacheKey),
              let cache = try? JSONDecoder().decode(WatchLedgerCache.self, from: data) else {
            return .empty
        }
        return cache
    }

    func save(_ cache: WatchLedgerCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: WatchLedgerConstants.cacheKey)
    }
}
