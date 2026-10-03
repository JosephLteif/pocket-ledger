import Foundation

enum PreciousMetal: String, Codable, CaseIterable, Identifiable, Sendable {
    case gold, silver
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var apiSymbol: String { self == .gold ? "XAU" : "XAG" }
}

enum MetalWeightUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case grams, troyOunces
    var id: String { rawValue }
    var displayName: String { self == .grams ? "Grams" : "Troy ounces" }
    var gramsPerUnit: Decimal { self == .grams ? 1 : Decimal(string: "31.1034768")! }
}

enum MetalPricingMode: String, Codable, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
}

struct MetalPriceSetting: Codable, Equatable {
    var metal: PreciousMetal
    var mode: MetalPricingMode = .automatic
    var manualPricePerGram: Decimal?
    var asOf: Date?
}

struct MetalQuote: Codable, Equatable, Sendable {
    var metal: PreciousMetal
    var usdPricePerTroyOunce: Decimal
    var marketDate: Date
    var fetchedAt: Date
    var nextRefreshAt: Date
}

struct MetalSale: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var enteredAt: Date = .now
    var weightGrams: Decimal
    var proceeds: Money
    var cost: Money
    var transactionIDs: [UUID] = []
    var gain: Money { Money(currency: cost.currency, minorUnits: proceeds.minorUnits - cost.minorUnits) }
}

struct MetalPurchase: Identifiable, Codable, Equatable {
    var id = UUID()
    var metal: PreciousMetal
    var description: String
    var date: Date
    var enteredAt: Date = .now
    var quantity: Decimal
    var weightPerItem: Decimal
    var unit: MetalWeightUnit
    var purity: Decimal
    var totalCost: Money
    var sales: [MetalSale] = []
    var transactionIDs: [UUID] = []
    var previousOpeningBalance: Money?
    var weightGrams: Decimal { quantity * weightPerItem * unit.gramsPerUnit }
    var remainingWeightGrams: Decimal { weightGrams - sales.reduce(0) { $0 + $1.weightGrams } }
    var remainingQuantity: Decimal { remainingWeightGrams / (weightPerItem * unit.gramsPerUnit) }
    var pureWeightGrams: Decimal { remainingWeightGrams * purity }
    var remainingCost: Money {
        Money(currency: totalCost.currency, minorUnits: totalCost.minorUnits - sales.reduce(0) { $0 + $1.cost.minorUnits })
    }
}

enum InvestmentEntryKind: String, Codable { case valuation, realization }

struct InvestmentEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var enteredAt: Date = .now
    var kind: InvestmentEntryKind
    var amount: Money
    var previousUnrealizedMinorUnits: Int64
    var transactionIDs: [UUID] = []
}

struct AccountTracking: Codable, Equatable {
    var metalPurchases: [MetalPurchase] = []
    var metalPricing: [MetalPriceSetting] = []
    var investmentEntries: [InvestmentEntry] = []
    var unrealizedMinorUnits: Int64 {
        guard let last = investmentEntries.last else { return 0 }
        return last.kind == .valuation ? last.amount.minorUnits : last.previousUnrealizedMinorUnits - last.amount.minorUnits
    }
    var lastValuation: InvestmentEntry? { investmentEntries.last { $0.kind == .valuation } }
    var transactionIDs: Set<UUID> {
        Set(metalPurchases.flatMap { $0.transactionIDs + $0.sales.flatMap(\.transactionIDs) }
            + investmentEntries.flatMap(\.transactionIDs))
    }
    var hasHistory: Bool { !metalPurchases.isEmpty || !investmentEntries.isEmpty }
}
