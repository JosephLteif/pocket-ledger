import Foundation

struct AssetTrackingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FinanceAssetTracking {
    static func money(_ amount: Decimal, currency: LedgerCurrency) throws -> Money {
        guard !amount.isNaN else { throw AssetTrackingError(message: "Enter a valid amount.") }
        var scaled = amount * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded <= Decimal(Int64.max), rounded >= Decimal(Int64.min + 1) else {
            throw AssetTrackingError(message: "Amount is too large.")
        }
        return Money(currency: currency, minorUnits: NSDecimalNumber(decimal: rounded).int64Value)
    }

    static func pricePerGram(account: Account, metal: PreciousMetal, data: FinanceData) -> Decimal? {
        let setting = account.tracking?.metalPricing.first { $0.metal == metal }
        if setting?.mode == .manual {
            guard let price = setting?.manualPricePerGram, !price.isNaN, price > 0 else { return nil }
            return price
        }
        guard let quote = data.metalQuotes.first(where: { $0.metal == metal }),
              !quote.usdPricePerTroyOunce.isNaN, quote.usdPricePerTroyOunce > 0 else { return nil }
        var price = quote.usdPricePerTroyOunce / MetalWeightUnit.troyOunces.gramsPerUnit
        if account.currency != .usd {
            if let rate = data.exchangeRates.first(where: { $0.baseCurrency == .usd && $0.quoteCurrency == account.currency }), rate.quoteUnitsPerBaseUnit > 0 {
                price *= rate.quoteUnitsPerBaseUnit
            } else if let rate = data.exchangeRates.first(where: { $0.quoteCurrency == .usd && $0.baseCurrency == account.currency }), rate.quoteUnitsPerBaseUnit > 0 {
                price /= rate.quoteUnitsPerBaseUnit
            } else { return nil }
        }
        return price > 0 && !price.isNaN ? price : nil
    }

    static func valuation(account: Account, recordedBalance: Money, data: FinanceData) -> Money {
        guard let tracking = account.tracking else { return recordedBalance }
        if account.type == .investment {
            return (try? money((Decimal(recordedBalance.minorUnits) + Decimal(tracking.unrealizedMinorUnits)) / Decimal(account.currency.minorUnitScale), currency: account.currency)) ?? recordedBalance
        }
        guard account.type == .physicalAsset, !tracking.metalPurchases.isEmpty else { return recordedBalance }
        let amount = tracking.metalPurchases.reduce(Decimal.zero) { total, purchase in
            if let price = pricePerGram(account: account, metal: purchase.metal, data: data) {
                return total + purchase.pureWeightGrams * price
            }
            return total + Decimal(purchase.remainingCost.minorUnits) / Decimal(account.currency.minorUnitScale)
        }
        return (try? money(amount, currency: account.currency)) ?? recordedBalance
    }

    private static func accountIndex(_ id: UUID, type: AccountType, in data: FinanceData) throws -> Int {
        guard let index = data.accounts.firstIndex(where: { $0.id == id && $0.type == type && !$0.isArchived }) else {
            throw AssetTrackingError(message: "Choose an active \(type.displayName.lowercased()) account.")
        }
        return index
    }

    private static func checkDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: .now) else {
            throw AssetTrackingError(message: "Choose a date that is not in the future.")
        }
    }

    private static func cashAccount(_ id: UUID, currency: LedgerCurrency, data: FinanceData) throws -> Account {
        guard let account = data.accounts.first(where: { $0.id == id }), !account.isArchived,
              account.currency == currency, account.type == .cash || account.type == .bankAccount else {
            throw AssetTrackingError(message: "Choose an active cash or bank account in \(currency.rawValue).")
        }
        return account
    }

    private static func transfer(from: UUID, to: UUID, amount: Money, date: Date, note: String) -> LedgerTransaction {
        LedgerTransaction(date: date, note: note, kind: .transfer, categoryID: nil,
            outflows: [MoneyMovement(accountID: from, money: amount)], inflows: [MoneyMovement(accountID: to, money: amount)])
    }

    private static func realization(accountID: UUID, amount: Money, date: Date, data: inout FinanceData) -> LedgerTransaction {
        let categoryID = UUID(uuidString: "D813760A-098C-4534-BEC3-5A723A3B9901")!
        if !data.categories.contains(where: { $0.id == categoryID }) {
            data.categories.append(LedgerCategory(id: categoryID, name: "Investment gains and losses", systemImage: "chart.line.uptrend.xyaxis"))
        }
        if let index = data.categories.firstIndex(where: { $0.id == categoryID }) { data.categories[index].isArchived = false }
        let movement = MoneyMovement(accountID: accountID, money: Money(currency: amount.currency, minorUnits: abs(amount.minorUnits)))
        return LedgerTransaction(date: date, note: amount.minorUnits > 0 ? "Realized investment gain" : "Realized investment loss",
            kind: amount.minorUnits > 0 ? .income : .expense, categoryID: categoryID,
            outflows: amount.minorUnits < 0 ? [movement] : [], inflows: amount.minorUnits > 0 ? [movement] : [])
    }

    static func addPurchase(in data: FinanceData, accountID: UUID, purchase: MetalPurchase, fundingAccountID: UUID?, reconcileOpeningBalance: Bool) throws -> FinanceData {
        let index = try accountIndex(accountID, type: .physicalAsset, in: data)
        let account = data.accounts[index]
        try checkDate(purchase.date)
        guard !purchase.quantity.isNaN, !purchase.weightPerItem.isNaN, !purchase.purity.isNaN,
              purchase.quantity > 0, purchase.weightPerItem > 0, purchase.purity > 0, purchase.purity <= 1,
              !purchase.weightGrams.isNaN, purchase.weightGrams <= Decimal(1_000_000_000),
              purchase.totalCost.currency == account.currency, purchase.totalCost.minorUnits > 0,
              purchase.sales.isEmpty, purchase.transactionIDs.isEmpty,
              !data.accounts.flatMap({ $0.tracking?.metalPurchases ?? [] }).contains(where: { $0.id == purchase.id }) else {
            throw AssetTrackingError(message: "Enter positive quantity, weight, cost, and a purity up to 100%.")
        }
        let balance = LedgerIndex(data: data).balance(for: account)
        let isFirstPurchase = account.tracking?.metalPurchases.isEmpty != false
        if isFirstPurchase && balance.minorUnits != 0 && !reconcileOpeningBalance {
            throw AssetTrackingError(message: "Confirm that holdings replace this account's recorded balance with their purchase cost.")
        }
        var updated = data
        var purchase = purchase
        purchase.enteredAt = .now
        purchase.previousOpeningBalance = account.openingBalance
        if isFirstPurchase {
            updated.accounts[index].openingBalance = try money((Decimal(account.openingBalance.minorUnits) - Decimal(balance.minorUnits)) / Decimal(account.currency.minorUnitScale), currency: account.currency)
            if updated.accounts[index].tracking == nil { updated.accounts[index].tracking = AccountTracking() }
        }
        if let fundingAccountID {
            _ = try cashAccount(fundingAccountID, currency: account.currency, data: data)
            let transaction = transfer(from: fundingAccountID, to: accountID, amount: purchase.totalCost, date: purchase.date, note: "Metal purchase: \(purchase.description)")
            purchase.transactionIDs = [transaction.id]
            updated.transactions.append(transaction)
        } else {
            updated.accounts[index].openingBalance = try money((Decimal(updated.accounts[index].openingBalance.minorUnits) + Decimal(purchase.totalCost.minorUnits)) / Decimal(account.currency.minorUnitScale), currency: account.currency)
        }
        updated.accounts[index].tracking?.metalPurchases.append(purchase)
        return updated
    }

    static func sell(in data: FinanceData, accountID: UUID, purchaseID: UUID, weightGrams: Decimal, proceeds: Money, date: Date, destinationAccountID: UUID) throws -> FinanceData {
        let index = try accountIndex(accountID, type: .physicalAsset, in: data)
        let account = data.accounts[index]
        guard let purchaseIndex = account.tracking?.metalPurchases.firstIndex(where: { $0.id == purchaseID }), let purchase = account.tracking?.metalPurchases[purchaseIndex] else {
            throw AssetTrackingError(message: "Purchase not found.")
        }
        try checkDate(date)
        guard Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: purchase.date), !weightGrams.isNaN, weightGrams > 0, weightGrams <= purchase.remainingWeightGrams,
              proceeds.currency == account.currency, proceeds.minorUnits >= 0 else {
            throw AssetTrackingError(message: "Check the sale date, remaining weight, and net proceeds.")
        }
        _ = try cashAccount(destinationAccountID, currency: account.currency, data: data)
        let cost = weightGrams == purchase.remainingWeightGrams ? purchase.remainingCost : try money(
            Decimal(purchase.remainingCost.minorUnits) / Decimal(account.currency.minorUnitScale) * weightGrams / purchase.remainingWeightGrams, currency: account.currency)
        var updated = data
        var sale = MetalSale(date: date, weightGrams: weightGrams, proceeds: proceeds, cost: cost)
        // Realize the difference inside the asset, then transfer the actual proceeds.
        if sale.gain.minorUnits != 0 {
            let transaction = realization(accountID: accountID, amount: sale.gain, date: date, data: &updated)
            sale.transactionIDs.append(transaction.id)
            updated.transactions.append(transaction)
        }
        if proceeds.minorUnits > 0 {
            let transaction = transfer(from: accountID, to: destinationAccountID, amount: proceeds, date: date, note: "Metal sale: \(purchase.description)")
            sale.transactionIDs.append(transaction.id)
            updated.transactions.append(transaction)
        }
        updated.accounts[index].tracking?.metalPurchases[purchaseIndex].sales.append(sale)
        return updated
    }

    static func updateInvestment(in data: FinanceData, accountID: UUID, amount: Money, date: Date, confirmRecordedBalance: Bool) throws -> FinanceData {
        let index = try accountIndex(accountID, type: .investment, in: data)
        let account = data.accounts[index]
        try checkDate(date)
        guard amount.currency == account.currency, amount.minorUnits != Int64.min else { throw AssetTrackingError(message: "Currency mismatch or invalid amount.") }
        guard account.tracking?.lastValuation != nil || confirmRecordedBalance else {
            throw AssetTrackingError(message: "Confirm that the recorded balance excludes this unrealized gain or loss.")
        }
        var updated = data
        if updated.accounts[index].tracking == nil { updated.accounts[index].tracking = AccountTracking() }
        let previous = account.tracking?.unrealizedMinorUnits ?? 0
        _ = try money((Decimal(LedgerIndex(data: data).balance(for: account).minorUnits) + Decimal(amount.minorUnits)) / Decimal(account.currency.minorUnitScale), currency: account.currency)
        updated.accounts[index].tracking?.investmentEntries.append(InvestmentEntry(date: date, kind: .valuation, amount: amount, previousUnrealizedMinorUnits: previous))
        return updated
    }

    static func realizeInvestment(in data: FinanceData, accountID: UUID, amount: Money, date: Date) throws -> FinanceData {
        let index = try accountIndex(accountID, type: .investment, in: data)
        let account = data.accounts[index]
        try checkDate(date)
        let unrealized = account.tracking?.unrealizedMinorUnits ?? 0
        guard amount.currency == account.currency, amount.minorUnits != 0, amount.minorUnits != Int64.min,
              (amount.minorUnits > 0 && unrealized > 0 && amount.minorUnits <= unrealized)
                || (amount.minorUnits < 0 && unrealized < 0 && amount.minorUnits >= unrealized),
              Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: account.tracking?.investmentEntries.last?.date ?? .distantPast) else {
            throw AssetTrackingError(message: "Realize part or all of the current gain or loss, on or after the latest entry.")
        }
        _ = try money((Decimal(LedgerIndex(data: data).balance(for: account).minorUnits) + Decimal(amount.minorUnits)) / Decimal(account.currency.minorUnitScale), currency: account.currency)
        var updated = data
        let transaction = realization(accountID: accountID, amount: amount, date: date, data: &updated)
        updated.transactions.append(transaction)
        updated.accounts[index].tracking?.investmentEntries.append(InvestmentEntry(date: date, kind: .realization, amount: amount, previousUnrealizedMinorUnits: unrealized, transactionIDs: [transaction.id]))
        return updated
    }

    static func undoLatest(in data: FinanceData, accountID: UUID) throws -> FinanceData {
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID }), let tracking = data.accounts[index].tracking else {
            throw AssetTrackingError(message: "No tracking history to undo.")
        }
        var updated = data
        var ids: [UUID] = []
        if !tracking.investmentEntries.isEmpty {
            ids = updated.accounts[index].tracking!.investmentEntries.removeLast().transactionIDs
        } else {
            let lastPurchase = tracking.metalPurchases.enumerated().max { $0.element.enteredAt < $1.element.enteredAt }
            let lastSale = tracking.metalPurchases.enumerated().compactMap { pair -> (Int, MetalSale)? in
                guard let sale = pair.element.sales.last else { return nil }
                return (pair.offset, sale)
            }.max { $0.1.enteredAt < $1.1.enteredAt }
            if let lastSale, lastSale.1.enteredAt >= (lastPurchase?.element.enteredAt ?? .distantPast) {
                ids = updated.accounts[index].tracking!.metalPurchases[lastSale.0].sales.removeLast().transactionIDs
            } else if let lastPurchase, lastPurchase.element.sales.isEmpty {
                let purchase = updated.accounts[index].tracking!.metalPurchases.remove(at: lastPurchase.offset)
                ids = purchase.transactionIDs
                if let previous = purchase.previousOpeningBalance { updated.accounts[index].openingBalance = previous }
            } else { throw AssetTrackingError(message: "No tracking history to undo.") }
        }
        guard ids.allSatisfy({ id in data.transactions.contains { $0.id == id } }) else {
            throw AssetTrackingError(message: "Linked ledger entries are missing; restore a backup before correcting this activity.")
        }
        updated.transactions.removeAll { ids.contains($0.id) }
        return updated
    }

    static func validationError(in data: FinanceData) -> String? {
        guard data.accounts.contains(where: { $0.tracking != nil }) || !data.metalQuotes.isEmpty else { return nil }
        guard Set(data.transactions.map(\.id)).count == data.transactions.count else { return "Duplicate ledger transaction IDs." }
        let transactions = Dictionary(uniqueKeysWithValues: data.transactions.map { ($0.id, $0) })
        func matchesRealization(_ transaction: LedgerTransaction, accountID: UUID, amount: Money) -> Bool {
            let movements = amount.minorUnits > 0 ? transaction.inflows : transaction.outflows
            guard amount.minorUnits != Int64.min, movements.count == 1, let movement = movements.first else { return false }
            return transaction.kind == (amount.minorUnits > 0 ? .income : .expense)
                && (amount.minorUnits > 0 ? transaction.outflows : transaction.inflows).isEmpty
                && movement.accountID == accountID && movement.money.currency == amount.currency
                && movement.money.minorUnits == abs(amount.minorUnits) && !movement.hasCategoryAssignment
        }
        func matchesTransfer(_ transaction: LedgerTransaction, from: UUID, to: UUID?, amount: Money) -> Bool {
            guard transaction.kind == .transfer, transaction.outflows.count == 1, transaction.inflows.count == 1,
                  let outflow = transaction.outflows.first, let inflow = transaction.inflows.first else { return false }
            return outflow.accountID == from && (to == nil || inflow.accountID == to)
                && outflow.money == amount && inflow.money == amount
                && !outflow.hasCategoryAssignment && !inflow.hasCategoryAssignment
        }
        var recordIDs: Set<UUID> = []
        var linkedIDs: Set<UUID> = []
        for account in data.accounts {
            guard let tracking = account.tracking else { continue }
            guard account.type == .physicalAsset || account.type == .investment,
                  account.type == .physicalAsset ? tracking.investmentEntries.isEmpty : tracking.metalPurchases.isEmpty else {
                return "Tracking does not match the account type."
            }
            for setting in tracking.metalPricing where setting.mode == .manual {
                guard let price = setting.manualPricePerGram, !price.isNaN, price > 0, price < 1_000_000_000,
                      let date = setting.asOf, date.timeIntervalSince1970.isFinite else { return "Invalid manual metal price." }
            }
            guard Set(tracking.metalPricing.map(\.metal)).count == tracking.metalPricing.count else { return "Duplicate metal pricing settings." }
            for purchase in tracking.metalPurchases {
                guard recordIDs.insert(purchase.id).inserted, !purchase.quantity.isNaN, !purchase.weightPerItem.isNaN,
                      !purchase.purity.isNaN, purchase.quantity > 0, purchase.weightPerItem > 0,
                      purchase.purity > 0, purchase.purity <= 1,
                      !purchase.weightGrams.isNaN, purchase.weightGrams <= 1_000_000_000,
                      purchase.totalCost.currency == account.currency, purchase.totalCost.minorUnits > 0,
                      purchase.previousOpeningBalance?.currency == account.currency,
                      purchase.date.timeIntervalSince1970.isFinite, purchase.enteredAt.timeIntervalSince1970.isFinite else {
                    return "Invalid metal purchase."
                }
                guard purchase.transactionIDs.count <= 1 else { return "Invalid purchase funding entries." }
                if let id = purchase.transactionIDs.first {
                    guard let transaction = transactions[id], let source = transaction.outflows.first?.accountID,
                          source != account.id, matchesTransfer(transaction, from: source, to: account.id, amount: purchase.totalCost) else {
                        return "Purchase does not match its funding transfer."
                    }
                }
                var weightLeft = purchase.weightGrams
                var costLeft = purchase.totalCost.minorUnits
                for sale in purchase.sales {
                    guard recordIDs.insert(sale.id).inserted, !sale.weightGrams.isNaN, sale.weightGrams > 0,
                          sale.weightGrams <= weightLeft, Calendar.current.startOfDay(for: sale.date) >= Calendar.current.startOfDay(for: purchase.date),
                          sale.enteredAt.timeIntervalSince1970.isFinite,
                          sale.proceeds.currency == account.currency, sale.proceeds.minorUnits >= 0,
                          sale.cost.currency == account.currency, sale.cost.minorUnits >= 0, sale.cost.minorUnits <= costLeft else {
                        return "Invalid metal sale."
                    }
                    let expected = sale.weightGrams == weightLeft ? costLeft : (try? money(
                        Decimal(costLeft) / Decimal(account.currency.minorUnitScale) * sale.weightGrams / weightLeft, currency: account.currency))?.minorUnits
                    guard sale.cost.minorUnits == expected else { return "Sale cost allocation does not match remaining weight." }
                    let expectedCount = (sale.gain.minorUnits == 0 ? 0 : 1) + (sale.proceeds.minorUnits == 0 ? 0 : 1)
                    guard sale.transactionIDs.count == expectedCount else { return "Sale ledger entries are missing." }
                    var transactionIndex = 0
                    if sale.gain.minorUnits != 0 {
                        guard let transaction = transactions[sale.transactionIDs[transactionIndex]],
                              matchesRealization(transaction, accountID: account.id, amount: sale.gain) else {
                            return "Sale gain or loss does not match its ledger entry."
                        }
                        transactionIndex += 1
                    }
                    if sale.proceeds.minorUnits > 0 {
                        guard let transaction = transactions[sale.transactionIDs[transactionIndex]],
                              transaction.inflows.first?.accountID != account.id,
                              matchesTransfer(transaction, from: account.id, to: nil, amount: sale.proceeds) else {
                            return "Sale proceeds do not match their transfer."
                        }
                    }
                    weightLeft -= sale.weightGrams
                    costLeft -= sale.cost.minorUnits
                }
            }
            var unrealized: Int64 = 0
            for entry in tracking.investmentEntries {
                guard recordIDs.insert(entry.id).inserted, entry.amount.currency == account.currency,
                      entry.amount.minorUnits != Int64.min, entry.previousUnrealizedMinorUnits == unrealized,
                      entry.date.timeIntervalSince1970.isFinite, entry.enteredAt.timeIntervalSince1970.isFinite else {
                    return "Invalid investment history."
                }
                if entry.kind == .valuation {
                    guard entry.transactionIDs.isEmpty else { return "Unrealized valuations cannot move money." }
                    unrealized = entry.amount.minorUnits
                } else {
                    let amount = entry.amount.minorUnits
                    guard (amount > 0 && unrealized > 0 && amount <= unrealized)
                        || (amount < 0 && unrealized < 0 && amount >= unrealized),
                          entry.transactionIDs.count == 1,
                          let transaction = transactions[entry.transactionIDs[0]],
                          matchesRealization(transaction, accountID: account.id, amount: entry.amount) else {
                        return "Realization does not match its linked ledger entry."
                    }
                    unrealized -= amount
                }
            }
            let references = tracking.metalPurchases.flatMap { $0.transactionIDs + $0.sales.flatMap(\.transactionIDs) }
                + tracking.investmentEntries.flatMap(\.transactionIDs)
            for id in references {
                guard linkedIDs.insert(id).inserted, let transaction = transactions[id],
                      (transaction.outflows + transaction.inflows).contains(where: { $0.accountID == account.id }) else {
                    return "Asset activity has a missing or reused ledger entry."
                }
            }
            if account.type == .physicalAsset && !tracking.metalPurchases.isEmpty {
                let cost = tracking.metalPurchases.reduce(Decimal.zero) { $0 + Decimal($1.remainingCost.minorUnits) }
                guard cost <= Decimal(Int64.max), cost >= 0,
                      LedgerIndex(data: data).balance(for: account).minorUnits == NSDecimalNumber(decimal: cost).int64Value else {
                    return "Recorded metal balance must match remaining purchase cost. Use the tracking controls to move metal principal."
                }
            }
        }
        guard Set(data.metalQuotes.map(\.metal)).count == data.metalQuotes.count,
              data.metalQuotes.allSatisfy({ !$0.usdPricePerTroyOunce.isNaN && $0.usdPricePerTroyOunce > 0
                  && $0.usdPricePerTroyOunce < 1_000_000 && $0.marketDate.timeIntervalSince1970.isFinite
                  && $0.fetchedAt.timeIntervalSince1970.isFinite && $0.nextRefreshAt.timeIntervalSince1970.isFinite }) else {
            return "Invalid cached metal quote."
        }
        return nil
    }
}
