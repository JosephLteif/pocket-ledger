import Foundation

enum LedgerCurrency: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case usd = "USD"
    case lbp = "LBP"
    case eur = "EUR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usd:
            return "US Dollar"
        case .lbp:
            return "Lebanese Pound"
        case .eur:
            return "Euro"
        }
    }

    var fractionDigits: Int {
        switch self {
        case .usd:
            return 2
        case .lbp:
            return 0
        case .eur:
            return 2
        }
    }

    var minorUnitScale: Int64 {
        switch self {
        case .usd:
            return 100
        case .lbp:
            return 1
        case .eur:
            return 100
        }
    }

    func formatted(minorUnits: Int64, locale: Locale = .current) -> String {
        let amount = Decimal(minorUnits) / Decimal(minorUnitScale)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: amount))
            ?? stableFormatted(minorUnits: minorUnits)
    }

    func stableFormatted(minorUnits: Int64) -> String {
        let isNegative = minorUnits < 0
        let amount = Decimal(minorUnits) / Decimal(minorUnitScale)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let number = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? String(describing: amount)
        let unsignedNumber = number.hasPrefix("-") ? String(number.dropFirst()) : number
        let sign = isNegative ? "-" : ""

        switch self {
        case .usd:
            return "\(sign)$\(unsignedNumber)"
        case .lbp:
            return "\(sign)LBP \(unsignedNumber)"
        case .eur:
            return "\(sign)€\(unsignedNumber)"
        }
    }

    func formattedInput(_ rawValue: String, locale: Locale = .current) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let money = Money.parse(trimmed, currency: self, locale: locale) else {
            return rawValue
        }

        return formattedInput(minorUnits: money.minorUnits, locale: locale)
    }

    func formattedInput(minorUnits: Int64, locale: Locale = .current) -> String {
        let amount = Decimal(minorUnits) / Decimal(minorUnitScale)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? String(describing: amount)
    }
}

struct Money: Codable, Equatable, Sendable {
    let currency: LedgerCurrency
    let minorUnits: Int64

    var formatted: String {
        formatted(locale: .current)
    }

    func formatted(locale: Locale) -> String {
        currency.formatted(minorUnits: minorUnits, locale: locale)
    }

    var stableFormatted: String {
        currency.stableFormatted(minorUnits: minorUnits)
    }

    func recast(to currency: LedgerCurrency) -> Money {
        guard self.currency != currency else { return self }

        let amount = Decimal(minorUnits) / Decimal(self.currency.minorUnitScale)
        let scaled = amount * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        var value = scaled
        NSDecimalRound(&rounded, &value, 0, .plain)
        return Money(
            currency: currency,
            minorUnits: NSDecimalNumber(decimal: rounded).int64Value
        )
    }

    func compactFormatted(locale: Locale = .current) -> String {
        let rawAmount = abs(NSDecimalNumber(decimal: Decimal(minorUnits) / Decimal(currency.minorUnitScale)).doubleValue)
        let (scaledAmount, suffix): (Double, String) = {
            switch rawAmount {
            case 1_000_000_000...:
                return (rawAmount / 1_000_000_000, "B")
            case 1_000_000...:
                return (rawAmount / 1_000_000, "M")
            case 1_000...:
                return (rawAmount / 1_000, "K")
            default:
                return (rawAmount, "")
            }
        }()

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = suffix.isEmpty ? currency.fractionDigits : 1
        let number = formatter.string(from: NSNumber(value: scaledAmount)) ?? String(scaledAmount)
        let sign = minorUnits < 0 ? "-" : ""
        let prefix: String
        switch currency {
        case .usd:
            prefix = "$"
        case .lbp:
            prefix = "LBP "
        case .eur:
            prefix = "€"
        }
        return "\(sign)\(prefix)\(number)\(suffix)"
    }

    static func parse(_ rawValue: String, currency: LedgerCurrency, locale: Locale = .current) -> Money? {
        let groupingSeparator = locale.groupingSeparator ?? ","
        let decimalSeparator = locale.decimalSeparator ?? "."
        var normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: groupingSeparator, with: "")

        if decimalSeparator != "." {
            normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        }

        guard !normalized.isEmpty else {
            return nil
        }

        let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
            ?? NumberFormatter.localizedDecimalFormatter(locale: locale).number(from: rawValue)?.decimalValue
        guard let decimal else { return nil }

        let scaled = decimal * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        var value = scaled
        NSDecimalRound(&rounded, &value, 0, .plain)
        return Money(
            currency: currency,
            minorUnits: NSDecimalNumber(decimal: rounded).int64Value
        )
    }
}

struct TransactionCategoryAllocation: Codable, Equatable {
    var categoryID: UUID?
    var amount: Money
}

private extension NumberFormatter {
    static func localizedDecimalFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        return formatter
    }
}

enum AccountType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case cash
    case bankAccount
    case loan
    case physicalAsset
    case investment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash:
            return "Cash"
        case .bankAccount:
            return "Bank account"
        case .loan:
            return "Loan"
        case .physicalAsset:
            return "Physical asset"
        case .investment:
            return "Investment"
        }
    }

    var systemImage: String {
        switch self {
        case .cash:
            return "banknote"
        case .bankAccount:
            return "building.columns"
        case .loan:
            return "arrow.triangle.2.circlepath"
        case .physicalAsset:
            return "diamond.fill"
        case .investment:
            return "chart.line.uptrend.xyaxis"
        }
    }
}

struct Account: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: AccountType
    var currency: LedgerCurrency
    var openingBalance: Money
    var includeInTotals: Bool
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        currency: LedgerCurrency,
        openingBalance: Money,
        includeInTotals: Bool = true,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.currency = currency
        self.openingBalance = openingBalance
        self.includeInTotals = includeInTotals
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case currency
        case openingBalance
        case includeInTotals
        case isArchived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(AccountType.self, forKey: .type)
        currency = try container.decode(LedgerCurrency.self, forKey: .currency)
        openingBalance = try container.decode(Money.self, forKey: .openingBalance)
        includeInTotals = try container.decodeIfPresent(Bool.self, forKey: .includeInTotals) ?? true
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(currency, forKey: .currency)
        try container.encode(openingBalance, forKey: .openingBalance)
        try container.encode(includeInTotals, forKey: .includeInTotals)
        try container.encode(isArchived, forKey: .isArchived)
    }
}

enum FinanceAccountCurrencyMigration {
    static func migrating(
        _ data: FinanceData,
        accountID: UUID,
        from oldCurrency: LedgerCurrency,
        to newCurrency: LedgerCurrency,
        preserveMovementCurrencies: Bool = false
    ) -> FinanceData {
        guard oldCurrency != newCurrency else { return data }

        var updated = data
        guard let accountIndex = updated.accounts.firstIndex(where: { $0.id == accountID }) else {
            return data
        }

        updated.accounts[accountIndex].currency = newCurrency
        updated.accounts[accountIndex].openingBalance = updated.accounts[accountIndex].openingBalance.recast(
            to: newCurrency
        )

        for index in updated.transactions.indices {
            var transaction = updated.transactions[index]
            migrate(
                outflows: &transaction.outflows,
                inflows: &transaction.inflows,
                amountDue: &transaction.amountDue,
                exchangeRate: &transaction.exchangeRate,
                changeAdjustment: &transaction.changeAdjustment,
                accountID: accountID,
                from: oldCurrency,
                to: newCurrency,
                preserveMovementCurrencies: preserveMovementCurrencies,
                kind: transaction.kind
            )
            updated.transactions[index] = transaction
        }

        for index in updated.scheduledTransactions.indices {
            var transaction = updated.scheduledTransactions[index]
            migrate(
                outflows: &transaction.outflows,
                inflows: &transaction.inflows,
                amountDue: &transaction.amountDue,
                exchangeRate: &transaction.exchangeRate,
                changeAdjustment: &transaction.changeAdjustment,
                accountID: accountID,
                from: oldCurrency,
                to: newCurrency,
                preserveMovementCurrencies: preserveMovementCurrencies,
                kind: transaction.kind
            )
            updated.scheduledTransactions[index] = transaction
        }

        for index in updated.templates.indices {
            var template = updated.templates[index]
            migrate(
                outflows: &template.outflows,
                inflows: &template.inflows,
                amountDue: &template.amountDue,
                exchangeRate: &template.exchangeRate,
                changeAdjustment: &template.changeAdjustment,
                accountID: accountID,
                from: oldCurrency,
                to: newCurrency,
                preserveMovementCurrencies: preserveMovementCurrencies,
                kind: template.kind
            )
            updated.templates[index] = template
        }

        return updated
    }

    private static func migrate(
        outflows: inout [MoneyMovement],
        inflows: inout [MoneyMovement],
        amountDue: inout Money?,
        exchangeRate: inout ExchangeRate?,
        changeAdjustment: inout ChangeAdjustment?,
        accountID: UUID,
        from oldCurrency: LedgerCurrency,
        to newCurrency: LedgerCurrency,
        preserveMovementCurrencies: Bool,
        kind: TransactionKind
    ) {
        var didMigrateMovement = false
        let originalExchangeRate = exchangeRate

        func positiveMoney(_ money: Money) -> Money {
            guard money.minorUnits < 0 else { return money }
            return Money(currency: money.currency, minorUnits: -money.minorUnits)
        }

        func migratedMoney(_ money: Money) -> Money {
            let normalizedMoney = positiveMoney(money)
            if let convertedMinorUnits = originalExchangeRate.flatMap({
                financeConvertedMinorUnits(
                    normalizedMoney,
                    to: newCurrency,
                    using: $0
                )
            }) {
                return Money(currency: newCurrency, minorUnits: convertedMinorUnits)
            }
            return normalizedMoney.recast(to: newCurrency)
        }

        func migrateMovements(_ movements: inout [MoneyMovement]) {
            for index in movements.indices where movements[index].accountID == accountID {
                if preserveMovementCurrencies {
                    let normalizedMoney = positiveMoney(movements[index].money)
                    guard normalizedMoney != movements[index].money else { continue }
                    movements[index].money = normalizedMoney
                } else {
                    guard movements[index].money.currency == oldCurrency else { continue }
                    movements[index].money = migratedMoney(movements[index].money)
                }
                didMigrateMovement = true
            }
        }

        migrateMovements(&outflows)
        migrateMovements(&inflows)
        guard didMigrateMovement else { return }

        if let value = amountDue, value.currency == oldCurrency {
            amountDue = migratedMoney(value)
        }

        if let change = changeAdjustment {
            changeAdjustment = ChangeAdjustment(
                requested: change.requested.currency == oldCurrency
                    ? migratedMoney(change.requested)
                    : change.requested,
                actual: change.actual.currency == oldCurrency
                    ? migratedMoney(change.actual)
                    : change.actual
            )
        }

        if var rate = exchangeRate {
            if rate.baseCurrency == oldCurrency {
                rate.baseCurrency = newCurrency
            }
            if rate.quoteCurrency == oldCurrency {
                rate.quoteCurrency = newCurrency
            }
            exchangeRate = rate.baseCurrency == rate.quoteCurrency ? nil : rate
        }

        guard kind == .transfer,
              Set((outflows + inflows).map { $0.money.currency }).count > 1,
              exchangeRate == nil,
              let source = outflows.first?.money,
              let destination = inflows.first?.money,
              source.minorUnits > 0,
              destination.minorUnits > 0 else {
            return
        }

        let sourceUnits = Decimal(source.minorUnits) / Decimal(source.currency.minorUnitScale)
        let destinationUnits = Decimal(destination.minorUnits) / Decimal(destination.currency.minorUnitScale)
        guard sourceUnits > 0, destinationUnits > 0 else { return }
        exchangeRate = ExchangeRate(
            baseCurrency: source.currency,
            quoteCurrency: destination.currency,
            quoteUnitsPerBaseUnit: destinationUnits / sourceUnits
        )
    }
}

enum TransactionKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case expense
    case income
    case transfer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expense:
            return "Expense"
        case .income:
            return "Income"
        case .transfer:
            return "Transfer"
        }
    }
}

enum ScheduleFrequency: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case once
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .once:
            return "Once"
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        case .yearly:
            return "Yearly"
        }
    }

    func nextDate(
        after date: Date,
        calendar: Calendar = .current,
        monthlyDay: Int? = nil,
        monthlyRule: ScheduleMonthlyRule = .dayOfMonth
    ) -> Date? {
        switch self {
        case .once:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: date),
                  let nextMonthInterval = calendar.dateInterval(of: .month, for: nextMonth),
                  let followingMonth = calendar.date(byAdding: .month, value: 1, to: nextMonthInterval.start),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: followingMonth) else {
                return nil
            }

            let maximumDay = calendar.component(.day, from: lastDay)
            let targetDay: Int
            switch monthlyRule {
            case .dayOfMonth:
                targetDay = min(max(monthlyDay ?? calendar.component(.day, from: date), 1), maximumDay)
            case .lastDayOfMonth:
                targetDay = maximumDay
            }

            var components = calendar.dateComponents([.year, .month, .hour, .minute, .second, .nanosecond], from: nextMonth)
            components.day = targetDay
            return calendar.date(from: components)
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
    }
}

enum ScheduleMonthlyRule: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case dayOfMonth
    case lastDayOfMonth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dayOfMonth:
            return "Same day each month"
        case .lastDayOfMonth:
            return "Last day of each month"
        }
    }
}

enum ScheduledReminderTiming: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case atDue
    case oneHourBefore
    case oneDayBefore
    case threeDaysBefore
    case oneWeekBefore
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .atDue:
            return "At due time"
        case .oneHourBefore:
            return "1 hour before"
        case .oneDayBefore:
            return "1 day before"
        case .threeDaysBefore:
            return "3 days before"
        case .oneWeekBefore:
            return "1 week before"
        case .none:
            return "Never"
        }
    }

    var leadTime: TimeInterval {
        switch self {
        case .atDue:
            return 0
        case .oneHourBefore:
            return 60 * 60
        case .oneDayBefore:
            return 24 * 60 * 60
        case .threeDaysBefore:
            return 3 * 24 * 60 * 60
        case .oneWeekBefore:
            return 7 * 24 * 60 * 60
        case .none:
            return .infinity
        }
    }
}

enum TransactionTiming: String, CaseIterable, Identifiable, Hashable, Sendable {
    case now
    case scheduled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .now:
            return "Now"
        case .scheduled:
            return "Schedule"
        }
    }
}

struct MoneyMovement: Identifiable, Codable, Equatable {
    let id: UUID
    var accountID: UUID
    var money: Money
    var categoryID: UUID?
    var hasCategoryAssignment: Bool

    init(
        id: UUID = UUID(),
        accountID: UUID,
        money: Money,
        categoryID: UUID? = nil,
        hasCategoryAssignment: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.money = money
        self.categoryID = categoryID
        self.hasCategoryAssignment = hasCategoryAssignment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case accountID
        case money
        case categoryID
        case hasCategoryAssignment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        money = try container.decode(Money.self, forKey: .money)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        hasCategoryAssignment = try container.decodeIfPresent(Bool.self, forKey: .hasCategoryAssignment) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(money, forKey: .money)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encode(hasCategoryAssignment, forKey: .hasCategoryAssignment)
    }
}

struct ExchangeRate: Codable, Equatable, Identifiable {
    var baseCurrency: LedgerCurrency
    var quoteCurrency: LedgerCurrency
    var quoteUnitsPerBaseUnit: Decimal
    var updatedAt: Date?

    init(
        baseCurrency: LedgerCurrency,
        quoteCurrency: LedgerCurrency,
        quoteUnitsPerBaseUnit: Decimal,
        updatedAt: Date? = nil
    ) {
        self.baseCurrency = baseCurrency
        self.quoteCurrency = quoteCurrency
        self.quoteUnitsPerBaseUnit = quoteUnitsPerBaseUnit
        self.updatedAt = updatedAt
    }

    var id: String {
        "\(baseCurrency.rawValue)-\(quoteCurrency.rawValue)"
    }

    var summary: String {
        let number = Self.formattedValue(quoteUnitsPerBaseUnit)
        return "1 \(baseCurrency.rawValue) = \(number) \(quoteCurrency.rawValue)"
    }

    var displaySummary: String {
        summary
    }

    static func formattedValue(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        var roundedValue = Decimal()
        var valueToRound = value
        NSDecimalRound(&roundedValue, &valueToRound, 2, .plain)
        return formatter.string(from: NSDecimalNumber(decimal: roundedValue))
            ?? NSDecimalNumber(decimal: roundedValue).stringValue
    }
}

struct ChangeAdjustment: Codable, Equatable {
    var requested: Money
    var actual: Money

    var shortfall: Money? {
        guard requested.currency == actual.currency else { return nil }
        let difference = requested.minorUnits - actual.minorUnits
        guard difference != 0 else { return nil }
        return Money(currency: requested.currency, minorUnits: difference)
    }
}

struct LedgerCategory: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var systemImage: String
    var includeInTotals: Bool
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        systemImage: String = "tag",
        includeInTotals: Bool = true,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.systemImage = systemImage
        self.includeInTotals = includeInTotals
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID
        case systemImage
        case includeInTotals
        case isArchived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        systemImage = try container.decodeIfPresent(String.self, forKey: .systemImage) ?? "tag"
        includeInTotals = try container.decodeIfPresent(Bool.self, forKey: .includeInTotals) ?? true
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encode(systemImage, forKey: .systemImage)
        try container.encode(includeInTotals, forKey: .includeInTotals)
        try container.encode(isArchived, forKey: .isArchived)
    }
}

struct LedgerTransaction: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var note: String
    var kind: TransactionKind
    var categoryID: UUID?
    var categoryAllocations: [TransactionCategoryAllocation]?
    var amountDue: Money?
    var outflows: [MoneyMovement]
    var inflows: [MoneyMovement]
    var exchangeRate: ExchangeRate?
    var changeAdjustment: ChangeAdjustment?
    var attachmentIDs: [UUID]
    var loanID: UUID?
    var loanPaymentID: UUID?
    var loanActivity: LoanLedgerActivity?
    var loanPrincipalAmount: Money?

    var effectiveCategoryIDs: [UUID?] {
        let categoryIDs: [UUID?]
        if kind == .expense, outflows.contains(where: \.hasCategoryAssignment) {
            categoryIDs = outflows.filter(\.hasCategoryAssignment).map(\.categoryID)
        } else {
            categoryIDs = categoryAllocations?.map(\.categoryID) ?? [categoryID]
        }
        var seen: Set<UUID?> = []
        return categoryIDs.filter { seen.insert($0).inserted }
    }

    init(
        id: UUID = UUID(),
        date: Date = .now,
        note: String,
        kind: TransactionKind,
        categoryID: UUID?,
        categoryAllocations: [TransactionCategoryAllocation]? = nil,
        amountDue: Money? = nil,
        outflows: [MoneyMovement],
        inflows: [MoneyMovement],
        exchangeRate: ExchangeRate? = nil,
        changeAdjustment: ChangeAdjustment? = nil,
        attachmentIDs: [UUID] = [],
        loanID: UUID? = nil,
        loanPaymentID: UUID? = nil,
        loanActivity: LoanLedgerActivity? = nil,
        loanPrincipalAmount: Money? = nil
    ) {
        self.id = id
        self.date = date
        self.note = note
        self.kind = kind
        self.categoryID = categoryID
        self.categoryAllocations = categoryAllocations
        self.amountDue = amountDue
        self.outflows = outflows
        self.inflows = inflows
        self.exchangeRate = exchangeRate
        self.changeAdjustment = changeAdjustment
        self.attachmentIDs = attachmentIDs
        self.loanID = loanID
        self.loanPaymentID = loanPaymentID
        self.loanActivity = loanActivity
        self.loanPrincipalAmount = loanPrincipalAmount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case note
        case kind
        case categoryID
        case categoryAllocations
        case amountDue
        case outflows
        case inflows
        case exchangeRate
        case changeAdjustment
        case attachmentIDs
        case loanID
        case loanPaymentID
        case loanActivity
        case loanPrincipalAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        note = try container.decode(String.self, forKey: .note)
        kind = try container.decode(TransactionKind.self, forKey: .kind)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        categoryAllocations = try container.decodeIfPresent(
            [TransactionCategoryAllocation].self,
            forKey: .categoryAllocations
        )
        amountDue = try container.decodeIfPresent(Money.self, forKey: .amountDue)
        outflows = try container.decode([MoneyMovement].self, forKey: .outflows)
        inflows = try container.decode([MoneyMovement].self, forKey: .inflows)
        exchangeRate = try container.decodeIfPresent(ExchangeRate.self, forKey: .exchangeRate)
        changeAdjustment = try container.decodeIfPresent(ChangeAdjustment.self, forKey: .changeAdjustment)
        attachmentIDs = try container.decodeIfPresent([UUID].self, forKey: .attachmentIDs) ?? []
        loanID = try container.decodeIfPresent(UUID.self, forKey: .loanID)
        loanPaymentID = try container.decodeIfPresent(UUID.self, forKey: .loanPaymentID)
        loanActivity = try container.decodeIfPresent(LoanLedgerActivity.self, forKey: .loanActivity)
        loanPrincipalAmount = try container.decodeIfPresent(Money.self, forKey: .loanPrincipalAmount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(note, forKey: .note)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(categoryAllocations, forKey: .categoryAllocations)
        try container.encodeIfPresent(amountDue, forKey: .amountDue)
        try container.encode(outflows, forKey: .outflows)
        try container.encode(inflows, forKey: .inflows)
        try container.encodeIfPresent(exchangeRate, forKey: .exchangeRate)
        try container.encodeIfPresent(changeAdjustment, forKey: .changeAdjustment)
        try container.encode(attachmentIDs, forKey: .attachmentIDs)
        try container.encodeIfPresent(loanID, forKey: .loanID)
        try container.encodeIfPresent(loanPaymentID, forKey: .loanPaymentID)
        try container.encodeIfPresent(loanActivity, forKey: .loanActivity)
        try container.encodeIfPresent(loanPrincipalAmount, forKey: .loanPrincipalAmount)
    }
}

enum LoanDirection: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case lent
    case borrowed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lent: "Lent"
        case .borrowed: "Borrowed"
        }
    }

    var counterpartyLabel: String {
        switch self {
        case .lent: "Borrower"
        case .borrowed: "Lender"
        }
    }
}

enum LoanLedgerActivity: String, Codable, Hashable, Sendable {
    case funding
    case payment
}

struct LoanPayment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var date: Date
    var amount: Money
    var transactionID: UUID

    init(id: UUID = UUID(), date: Date, amount: Money, transactionID: UUID) {
        self.id = id
        self.date = date
        self.amount = amount
        self.transactionID = transactionID
    }
}

struct LoanContact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct Loan: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var counterparty: String
    var counterpartyContactID: UUID?
    var direction: LoanDirection
    var currency: LedgerCurrency
    var startingAmount: Money
    var startedAt: Date
    var dueDate: Date?
    var settlementAccountID: UUID?
    var fundingTransactionID: UUID?
    var legacyAccountID: UUID?
    var payments: [LoanPayment]

    init(
        id: UUID = UUID(),
        counterparty: String,
        counterpartyContactID: UUID? = nil,
        direction: LoanDirection,
        currency: LedgerCurrency,
        startingAmount: Money,
        startedAt: Date = .now,
        dueDate: Date? = nil,
        settlementAccountID: UUID? = nil,
        fundingTransactionID: UUID? = nil,
        legacyAccountID: UUID? = nil,
        payments: [LoanPayment] = []
    ) {
        self.id = id
        self.counterparty = counterparty
        self.counterpartyContactID = counterpartyContactID
        self.direction = direction
        self.currency = currency
        self.startingAmount = startingAmount
        self.startedAt = startedAt
        self.dueDate = dueDate
        self.settlementAccountID = settlementAccountID
        self.fundingTransactionID = fundingTransactionID
        self.legacyAccountID = legacyAccountID
        self.payments = payments
    }

    var outstandingAmount: Money {
        Money(
            currency: currency,
            minorUnits: startingAmount.minorUnits - payments.reduce(Int64.zero) {
                $0 + $1.amount.minorUnits
            }
        )
    }

    var isSettled: Bool { outstandingAmount.minorUnits == 0 }
}

struct ScheduledTransaction: Identifiable, Codable, Equatable {
    let id: UUID
    var nextRunDate: Date
    var frequency: ScheduleFrequency
    var monthlyRule: ScheduleMonthlyRule
    var recurrenceDay: Int
    var isEnabled: Bool
    /// `nil` means the global reminder preference is used.
    var reminderTiming: ScheduledReminderTiming?
    var lastRunDate: Date?
    var lastSkippedDate: Date?
    var note: String
    var kind: TransactionKind
    var categoryID: UUID?
    var amountDue: Money?
    var outflows: [MoneyMovement]
    var inflows: [MoneyMovement]
    var exchangeRate: ExchangeRate?
    var changeAdjustment: ChangeAdjustment?

    init(
        id: UUID = UUID(),
        nextRunDate: Date,
        frequency: ScheduleFrequency,
        monthlyRule: ScheduleMonthlyRule = .dayOfMonth,
        recurrenceDay: Int? = nil,
        isEnabled: Bool = true,
        reminderTiming: ScheduledReminderTiming? = nil,
        lastRunDate: Date? = nil,
        lastSkippedDate: Date? = nil,
        note: String,
        kind: TransactionKind,
        categoryID: UUID?,
        amountDue: Money? = nil,
        outflows: [MoneyMovement],
        inflows: [MoneyMovement],
        exchangeRate: ExchangeRate? = nil,
        changeAdjustment: ChangeAdjustment? = nil
    ) {
        self.id = id
        self.nextRunDate = nextRunDate
        self.frequency = frequency
        self.monthlyRule = monthlyRule
        self.recurrenceDay = min(max(recurrenceDay ?? Calendar.current.component(.day, from: nextRunDate), 1), 31)
        self.isEnabled = isEnabled
        self.reminderTiming = reminderTiming
        self.lastRunDate = lastRunDate
        self.lastSkippedDate = lastSkippedDate
        self.note = note
        self.kind = kind
        self.categoryID = categoryID
        self.amountDue = amountDue
        self.outflows = outflows
        self.inflows = inflows
        self.exchangeRate = exchangeRate
        self.changeAdjustment = changeAdjustment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nextRunDate
        case frequency
        case monthlyRule
        case recurrenceDay
        case isEnabled
        case reminderTiming
        case lastRunDate
        case lastSkippedDate
        case note
        case kind
        case categoryID
        case amountDue
        case outflows
        case inflows
        case exchangeRate
        case changeAdjustment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nextRunDate = try container.decode(Date.self, forKey: .nextRunDate)
        frequency = try container.decode(ScheduleFrequency.self, forKey: .frequency)
        monthlyRule = try container.decodeIfPresent(
            ScheduleMonthlyRule.self,
            forKey: .monthlyRule
        ) ?? .dayOfMonth
        recurrenceDay = min(
            max(
                try container.decodeIfPresent(Int.self, forKey: .recurrenceDay)
                    ?? Calendar.current.component(.day, from: nextRunDate),
                1
            ),
            31
        )
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        reminderTiming = try container.decodeIfPresent(
            ScheduledReminderTiming.self,
            forKey: .reminderTiming
        )
        lastRunDate = try container.decodeIfPresent(Date.self, forKey: .lastRunDate)
        lastSkippedDate = try container.decodeIfPresent(Date.self, forKey: .lastSkippedDate)
        note = try container.decode(String.self, forKey: .note)
        kind = try container.decode(TransactionKind.self, forKey: .kind)
        categoryID = try container.decodeIfPresent(UUID.self, forKey: .categoryID)
        amountDue = try container.decodeIfPresent(Money.self, forKey: .amountDue)
        outflows = try container.decode([MoneyMovement].self, forKey: .outflows)
        inflows = try container.decode([MoneyMovement].self, forKey: .inflows)
        exchangeRate = try container.decodeIfPresent(ExchangeRate.self, forKey: .exchangeRate)
        changeAdjustment = try container.decodeIfPresent(ChangeAdjustment.self, forKey: .changeAdjustment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nextRunDate, forKey: .nextRunDate)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(monthlyRule, forKey: .monthlyRule)
        try container.encode(recurrenceDay, forKey: .recurrenceDay)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(reminderTiming, forKey: .reminderTiming)
        try container.encodeIfPresent(lastRunDate, forKey: .lastRunDate)
        try container.encodeIfPresent(lastSkippedDate, forKey: .lastSkippedDate)
        try container.encode(note, forKey: .note)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(amountDue, forKey: .amountDue)
        try container.encode(outflows, forKey: .outflows)
        try container.encode(inflows, forKey: .inflows)
        try container.encodeIfPresent(exchangeRate, forKey: .exchangeRate)
        try container.encodeIfPresent(changeAdjustment, forKey: .changeAdjustment)
    }

    var transactionTemplate: LedgerTransaction {
        LedgerTransaction(
            date: nextRunDate,
            note: note,
            kind: kind,
            categoryID: categoryID,
            amountDue: amountDue,
            outflows: outflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            inflows: inflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            exchangeRate: exchangeRate,
            changeAdjustment: changeAdjustment
        )
    }

    func materializedTransaction(on date: Date) -> LedgerTransaction {
        LedgerTransaction(
            date: date,
            note: note,
            kind: kind,
            categoryID: categoryID,
            amountDue: amountDue,
            outflows: outflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            inflows: inflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            exchangeRate: exchangeRate,
            changeAdjustment: changeAdjustment
        )
    }
}

struct FinanceWidgetSnapshot: Equatable, Sendable {
    let usdAvailable: Money
    let lbpAvailable: Money
    let eurAvailable: Money
    let latestTransactionDescription: String
    let lastUpdated: Date
    let appGroupAvailable: Bool
    let attentionCount: Int
    let upcomingScheduledCount: Int

    var balanceSummary: String {
        [usdAvailable, lbpAvailable, eurAvailable]
            .map(\.formatted)
            .joined(separator: " · ")
    }
}

struct LedgerBudget: Identifiable, Codable, Equatable {
    let id: UUID
    var categoryID: UUID
    var currency: LedgerCurrency
    var monthlyLimit: Money
    var rollover: Bool
    var startedAt: Date?

    init(
        id: UUID = UUID(),
        categoryID: UUID,
        currency: LedgerCurrency,
        monthlyLimit: Money,
        rollover: Bool = false,
        startedAt: Date? = .now
    ) {
        self.id = id
        self.categoryID = categoryID
        self.currency = currency
        self.monthlyLimit = monthlyLimit
        self.rollover = rollover
        self.startedAt = startedAt
    }
}

struct FinanceAttentionState: Codable, Equatable {
    var dismissedIDs: Set<String>

    init(dismissedIDs: Set<String> = []) {
        self.dismissedIDs = dismissedIDs
    }
}

struct AccountReconciliation: Codable, Equatable {
    var lastReconciledAt: Date
    var difference: Money
    var statementDate: Date?
    var statementBalance: Money?
    var clearedTransactionIDs: Set<UUID>
    var didRecordAdjustment: Bool

    init(
        lastReconciledAt: Date,
        difference: Money,
        statementDate: Date? = nil,
        statementBalance: Money? = nil,
        clearedTransactionIDs: Set<UUID> = [],
        didRecordAdjustment: Bool = false
    ) {
        self.lastReconciledAt = lastReconciledAt
        self.difference = difference
        self.statementDate = statementDate
        self.statementBalance = statementBalance
        self.clearedTransactionIDs = clearedTransactionIDs
        self.didRecordAdjustment = didRecordAdjustment
    }

    private enum CodingKeys: String, CodingKey {
        case lastReconciledAt, difference, statementDate, statementBalance, clearedTransactionIDs, didRecordAdjustment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastReconciledAt = try container.decode(Date.self, forKey: .lastReconciledAt)
        difference = try container.decode(Money.self, forKey: .difference)
        statementDate = try container.decodeIfPresent(Date.self, forKey: .statementDate)
        statementBalance = try container.decodeIfPresent(Money.self, forKey: .statementBalance)
        clearedTransactionIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .clearedTransactionIDs) ?? []
        didRecordAdjustment = try container.decodeIfPresent(Bool.self, forKey: .didRecordAdjustment) ?? false
    }
}

func financeConvertedMinorUnits(
    _ money: Money,
    to currency: LedgerCurrency,
    using exchangeRate: ExchangeRate?
) -> Int64? {
    guard money.currency != currency else { return money.minorUnits }
    guard let exchangeRate, exchangeRate.quoteUnitsPerBaseUnit > 0 else { return nil }

    let sourceUnits = Decimal(money.minorUnits) / Decimal(money.currency.minorUnitScale)
    let targetUnits: Decimal
    if money.currency == exchangeRate.baseCurrency,
       currency == exchangeRate.quoteCurrency {
        targetUnits = sourceUnits * exchangeRate.quoteUnitsPerBaseUnit
    } else if money.currency == exchangeRate.quoteCurrency,
              currency == exchangeRate.baseCurrency {
        targetUnits = sourceUnits / exchangeRate.quoteUnitsPerBaseUnit
    } else {
        return nil
    }

    var rounded = Decimal()
    var scaled = targetUnits * Decimal(currency.minorUnitScale)
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return NSDecimalNumber(decimal: rounded).int64Value
}

func financeNetExpenseAmount(
    _ transaction: LedgerTransaction,
    currency: LedgerCurrency,
    in data: FinanceData
) -> Int64 {
    guard transaction.kind == .expense else { return 0 }
    let accountsByID = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
    return financeCategoryAllocationAmounts(
        transaction,
        currency: currency,
        accountsByID: accountsByID
    )
    .filter { financeCategoryIncludedInTotals($0.categoryID, in: data.categories) }
    .reduce(Int64.zero) { $0 + $1.amount.minorUnits }
}

func financeCategoryAllocationAmounts(
    _ transaction: LedgerTransaction,
    currency: LedgerCurrency,
    accountsByID: [UUID: Account]
) -> [TransactionCategoryAllocation] {
    guard transaction.kind == .expense else { return [] }

    func includedAmount(_ movements: [MoneyMovement]) -> Int64 {
        movements.reduce(Int64.zero) { total, movement in
            guard accountsByID[movement.accountID]?.includeInTotals == true,
                  let amount = financeConvertedMinorUnits(
                      movement.money,
                      to: currency,
                      using: transaction.exchangeRate
                  ) else {
                return total
            }
            return total + amount
        }
    }

    let netAmount = max(includedAmount(transaction.outflows) - includedAmount(transaction.inflows), 0)
    guard netAmount > 0 else { return [] }

    let converted: [(categoryID: UUID?, amount: Int64)]
    if transaction.outflows.contains(where: \.hasCategoryAssignment) {
        var paymentAmounts: [(categoryID: UUID?, amount: Int64)] = []
        for movement in transaction.outflows where movement.hasCategoryAssignment {
            guard accountsByID[movement.accountID]?.includeInTotals == true,
                  let amount = financeConvertedMinorUnits(
                      movement.money,
                      to: currency,
                      using: transaction.exchangeRate
                  ), amount > 0 else {
                continue
            }
            if let index = paymentAmounts.firstIndex(where: { $0.categoryID == movement.categoryID }) {
                paymentAmounts[index].amount += amount
            } else {
                paymentAmounts.append((movement.categoryID, amount))
            }
        }
        converted = paymentAmounts
    } else if let savedAllocations = transaction.categoryAllocations?.filter({ $0.amount.minorUnits > 0 }) {
        converted = savedAllocations.compactMap { allocation -> (categoryID: UUID?, amount: Int64)? in
            guard let amount = financeConvertedMinorUnits(
                allocation.amount,
                to: currency,
                using: transaction.exchangeRate
            ), amount > 0 else {
                return nil
            }
            return (allocation.categoryID, amount)
        }
    } else {
        return [TransactionCategoryAllocation(
            categoryID: transaction.categoryID,
            amount: Money(currency: currency, minorUnits: netAmount)
        )]
    }
    guard !converted.isEmpty else {
        return [TransactionCategoryAllocation(
            categoryID: transaction.categoryID,
            amount: Money(currency: currency, minorUnits: netAmount)
        )]
    }

    let convertedTotal = converted.reduce(Int64.zero) { $0 + $1.amount }
    guard convertedTotal > 0 else { return [] }
    var amounts = converted.map { allocation in
        var rounded = Decimal()
        var ratio = Decimal(netAmount) * Decimal(allocation.amount) / Decimal(convertedTotal)
        NSDecimalRound(&rounded, &ratio, 0, .down)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
    let remainder = netAmount - amounts.reduce(Int64.zero, +)
    if let largestIndex = amounts.indices.max(by: { amounts[$0] < amounts[$1] }) {
        amounts[largestIndex] += remainder
    }

    return zip(converted, amounts).map { allocation, amount in
        TransactionCategoryAllocation(
            categoryID: allocation.categoryID,
            amount: Money(currency: currency, minorUnits: amount)
        )
    }
}

func financeCategoryIncludedInTotals(_ categoryID: UUID?, in categories: [LedgerCategory]) -> Bool {
    guard var currentID = categoryID else { return true }
    var visited: Set<UUID> = []

    while !visited.contains(currentID),
          let category = categories.first(where: { $0.id == currentID }) {
        visited.insert(currentID)
        let categoryName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if category.parentID == nil,
           categoryName.caseInsensitiveCompare("Modified Bal.") == .orderedSame {
            return false
        }
        guard category.includeInTotals else { return false }
        guard let parentID = category.parentID else { return true }
        currentID = parentID
    }

    return true
}

func financeBudgetSpent(
    _ budget: LedgerBudget,
    in data: FinanceData,
    interval: DateInterval? = nil
) -> Money {
    let period = interval ?? (
        Calendar.current.dateInterval(of: .month, for: .now)
            ?? DateInterval(start: .distantPast, duration: .zero)
    )
    let accountsByID = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
    let spent = data.transactions
        .filter {
            $0.kind == .expense
                && period.contains($0.date)
        }
        .reduce(Int64.zero) { total, transaction in
            let amount = financeCategoryAllocationAmounts(
                transaction,
                currency: budget.currency,
                accountsByID: accountsByID
            )
            .filter {
                $0.categoryID == budget.categoryID
                    && financeCategoryIncludedInTotals($0.categoryID, in: data.categories)
            }
            .reduce(Int64.zero) { $0 + $1.amount.minorUnits }
            return total + amount
        }
    return Money(currency: budget.currency, minorUnits: spent)
}

func financeBudgetAllowance(
    _ budget: LedgerBudget,
    in data: FinanceData,
    interval: DateInterval? = nil
) -> Money {
    let currentMonth = interval ?? (
        Calendar.current.dateInterval(of: .month, for: .now)
            ?? DateInterval(start: .distantPast, duration: .zero)
    )
    guard budget.rollover else { return budget.monthlyLimit }

    let calendar = Calendar.current
    let startingMonth = calendar.dateInterval(
        of: .month,
        for: budget.startedAt ?? currentMonth.start
    )?.start ?? currentMonth.start
    var month = startingMonth
    var carry = Int64.zero

    while month < currentMonth.start {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else {
            break
        }
        let spent = financeBudgetSpent(budget, in: data, interval: monthInterval).minorUnits
        carry = max(carry + budget.monthlyLimit.minorUnits - spent, 0)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: month),
              nextMonth > month else {
            break
        }
        month = nextMonth
    }

    return Money(
        currency: budget.currency,
        minorUnits: budget.monthlyLimit.minorUnits + carry
    )
}

struct LedgerTemplate: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var note: String
    var kind: TransactionKind
    var categoryID: UUID?
    var amountDue: Money?
    var outflows: [MoneyMovement]
    var inflows: [MoneyMovement]
    var exchangeRate: ExchangeRate?
    var changeAdjustment: ChangeAdjustment?

    init(
        id: UUID = UUID(),
        name: String,
        note: String,
        kind: TransactionKind,
        categoryID: UUID?,
        amountDue: Money?,
        outflows: [MoneyMovement],
        inflows: [MoneyMovement],
        exchangeRate: ExchangeRate?,
        changeAdjustment: ChangeAdjustment?
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.kind = kind
        self.categoryID = categoryID
        self.amountDue = amountDue
        self.outflows = outflows
        self.inflows = inflows
        self.exchangeRate = exchangeRate
        self.changeAdjustment = changeAdjustment
    }

    init(name: String, transaction: LedgerTransaction) {
        self.init(
            name: name,
            note: transaction.note,
            kind: transaction.kind,
            categoryID: transaction.categoryID,
            amountDue: transaction.amountDue,
            outflows: transaction.outflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            inflows: transaction.inflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            exchangeRate: transaction.exchangeRate,
            changeAdjustment: transaction.changeAdjustment
        )
    }

    var transactionTemplate: LedgerTransaction {
        LedgerTransaction(
            note: note,
            kind: kind,
            categoryID: categoryID,
            amountDue: amountDue,
            outflows: outflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            inflows: inflows.map { MoneyMovement(accountID: $0.accountID, money: $0.money) },
            exchangeRate: exchangeRate,
            changeAdjustment: changeAdjustment
        )
    }
}

struct LedgerReceiptLineItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var quantity: Int
    var unitPrice: Money?
    var lineTotal: Money?

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int,
        unitPrice: Money?,
        lineTotal: Money?
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.lineTotal = lineTotal
    }
}

struct LedgerAttachment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var fileName: String
    var contentType: String
    var relativePath: String
    var createdAt: Date
    var receiptItems: [LedgerReceiptLineItem]
    var extractedTotal: Money?

    init(
        id: UUID = UUID(),
        fileName: String,
        contentType: String,
        relativePath: String,
        createdAt: Date = .now,
        receiptItems: [LedgerReceiptLineItem] = [],
        extractedTotal: Money? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.contentType = contentType
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.receiptItems = receiptItems
        self.extractedTotal = extractedTotal
    }
}

struct FinanceData: Codable, Equatable {
    var accounts: [Account]
    var categories: [LedgerCategory]
    var transactions: [LedgerTransaction]
    var loans: [Loan]
    var loanContacts: [LoanContact]
    var managedLegacyLoanAccountIDs: Set<UUID>
    var scheduledTransactions: [ScheduledTransaction]
    var exchangeRates: [ExchangeRate]
    var budgets: [LedgerBudget]
    var templates: [LedgerTemplate]
    var attachments: [LedgerAttachment]
    var attentionState: FinanceAttentionState
    var reconciliations: [UUID: AccountReconciliation]

    init(
        accounts: [Account],
        categories: [LedgerCategory],
        transactions: [LedgerTransaction],
        loans: [Loan] = [],
        loanContacts: [LoanContact] = [],
        managedLegacyLoanAccountIDs: Set<UUID> = [],
        scheduledTransactions: [ScheduledTransaction] = [],
        exchangeRates: [ExchangeRate] = [],
        budgets: [LedgerBudget] = [],
        templates: [LedgerTemplate] = [],
        attachments: [LedgerAttachment] = [],
        attentionState: FinanceAttentionState = FinanceAttentionState(),
        reconciliations: [UUID: AccountReconciliation] = [:]
    ) {
        self.accounts = accounts
        self.categories = categories
        self.transactions = transactions
        self.loans = loans
        self.loanContacts = loanContacts
        self.managedLegacyLoanAccountIDs = managedLegacyLoanAccountIDs
        self.scheduledTransactions = scheduledTransactions
        self.exchangeRates = exchangeRates
        self.budgets = budgets
        self.templates = templates
        self.attachments = attachments
        self.attentionState = attentionState
        self.reconciliations = reconciliations
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case categories
        case transactions
        case loans
        case loanContacts
        case managedLegacyLoanAccountIDs
        case scheduledTransactions
        case exchangeRates
        case budgets
        case templates
        case attachments
        case attentionState
        case reconciliations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decode([Account].self, forKey: .accounts)
        categories = try container.decode([LedgerCategory].self, forKey: .categories)
        transactions = try container.decode([LedgerTransaction].self, forKey: .transactions)
        loans = try container.decodeIfPresent([Loan].self, forKey: .loans) ?? []
        loanContacts = try container.decodeIfPresent([LoanContact].self, forKey: .loanContacts) ?? []
        managedLegacyLoanAccountIDs = try container.decodeIfPresent(
            Set<UUID>.self,
            forKey: .managedLegacyLoanAccountIDs
        ) ?? []
        scheduledTransactions = try container.decodeIfPresent(
            [ScheduledTransaction].self,
            forKey: .scheduledTransactions
        ) ?? []
        exchangeRates = try container.decodeIfPresent(
            [ExchangeRate].self,
            forKey: .exchangeRates
        ) ?? []
        budgets = try container.decodeIfPresent([LedgerBudget].self, forKey: .budgets) ?? []
        templates = try container.decodeIfPresent([LedgerTemplate].self, forKey: .templates) ?? []
        attachments = try container.decodeIfPresent([LedgerAttachment].self, forKey: .attachments) ?? []
        attentionState = try container.decodeIfPresent(
            FinanceAttentionState.self,
            forKey: .attentionState
        ) ?? FinanceAttentionState()
        reconciliations = try container.decodeIfPresent(
            [UUID: AccountReconciliation].self,
            forKey: .reconciliations
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(categories, forKey: .categories)
        try container.encode(transactions, forKey: .transactions)
        try container.encode(loans, forKey: .loans)
        try container.encode(loanContacts, forKey: .loanContacts)
        try container.encode(managedLegacyLoanAccountIDs, forKey: .managedLegacyLoanAccountIDs)
        try container.encode(scheduledTransactions, forKey: .scheduledTransactions)
        try container.encode(exchangeRates, forKey: .exchangeRates)
        try container.encode(budgets, forKey: .budgets)
        try container.encode(templates, forKey: .templates)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(attentionState, forKey: .attentionState)
        try container.encode(reconciliations, forKey: .reconciliations)
    }

    static var empty: FinanceData {
        FinanceData(accounts: [], categories: [], transactions: [], scheduledTransactions: [])
    }
}
