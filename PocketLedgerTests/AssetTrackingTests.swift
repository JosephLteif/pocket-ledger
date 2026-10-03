import XCTest
@testable import PocketLedger

final class AssetTrackingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ type: AccountType, balance: Int64 = 0, currency: LedgerCurrency = .usd) -> Account {
        Account(name: type.displayName, type: type, currency: currency,
                openingBalance: Money(currency: currency, minorUnits: balance))
    }

    private func purchase(weight: Decimal = 3, cost: Int64 = 100, purity: Decimal = 1,
                          unit: MetalWeightUnit = .grams, quantity: Decimal = 1) -> MetalPurchase {
        MetalPurchase(metal: .gold, description: "Gold", date: date, quantity: quantity,
                      weightPerItem: weight, unit: unit, purity: purity,
                      totalCost: Money(currency: .usd, minorUnits: cost))
    }

    func testWeightQuantityAndPurityConversions() {
        let grams = purchase(weight: 10, purity: Decimal(string: "0.75")!, quantity: 2)
        XCTAssertEqual(grams.weightGrams, 20)
        XCTAssertEqual(grams.pureWeightGrams, 15)
        XCTAssertEqual(grams.remainingQuantity, 2)
        let ounces = purchase(weight: 1, unit: .troyOunces, quantity: 2)
        XCTAssertEqual(ounces.weightGrams, Decimal(string: "62.2069536")!)
    }

    func testHistoricalHoldingsReconcileAndUndoOpeningBalance() throws {
        let asset = account(.physicalAsset, balance: 50_000)
        let initial = FinanceData(accounts: [asset], categories: [], transactions: [])
        let first = purchase(cost: 10_000)
        XCTAssertThrowsError(try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: first, fundingAccountID: nil, reconcileOpeningBalance: false))
        let added = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: first, fundingAccountID: nil, reconcileOpeningBalance: true)
        XCTAssertEqual(LedgerIndex(data: added).balance(for: added.accounts[0]).minorUnits, 10_000)
        XCTAssertTrue(added.transactions.isEmpty)
        let undone = try FinanceAssetTracking.undoLatest(in: added, accountID: asset.id)
        XCTAssertEqual(LedgerIndex(data: undone).balance(for: undone.accounts[0]).minorUnits, 50_000)
        XCTAssertEqual(LedgerIndex(data: undone).valuation(for: undone.accounts[0]).minorUnits, 50_000)
        XCTAssertThrowsError(try FinanceAssetTracking.addPurchase(in: undone, accountID: asset.id,
            purchase: first, fundingAccountID: nil, reconcileOpeningBalance: false))
        let readded = try FinanceAssetTracking.addPurchase(in: undone, accountID: asset.id,
            purchase: first, fundingAccountID: nil, reconcileOpeningBalance: true)
        XCTAssertEqual(LedgerIndex(data: readded).balance(for: readded.accounts[0]).minorUnits, 10_000)
        XCTAssertNil(FinanceAssetTracking.validationError(in: readded))
    }

    func testFundedPurchaseTransfersCostWithoutChangingCombinedBalance() throws {
        let asset = account(.physicalAsset)
        let cash = account(.cash, balance: 50_000)
        let initial = FinanceData(accounts: [asset, cash], categories: [], transactions: [])
        let added = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: purchase(cost: 12_500), fundingAccountID: cash.id, reconcileOpeningBalance: false)
        let index = LedgerIndex(data: added)
        XCTAssertEqual(index.balance(for: added.accounts[0]).minorUnits, 12_500)
        XCTAssertEqual(index.balance(for: cash).minorUnits, 37_500)
        XCTAssertEqual(added.transactions.count, 1)
        XCTAssertEqual(added.transactions[0].kind, .transfer)
        let undone = try FinanceAssetTracking.undoLatest(in: added, accountID: asset.id)
        XCTAssertTrue(undone.transactions.isEmpty)
        XCTAssertEqual(LedgerIndex(data: undone).balance(for: cash).minorUnits, 50_000)
    }

    func testPartialAndFullSalesAllocateAllCostAndRecordGainAndLoss() throws {
        let asset = account(.physicalAsset)
        let cash = account(.bankAccount)
        let initial = FinanceData(accounts: [asset, cash], categories: [], transactions: [])
        let holding = purchase(weight: 3, cost: 100)
        var data = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: holding, fundingAccountID: nil, reconcileOpeningBalance: false)
        data = try FinanceAssetTracking.sell(in: data, accountID: asset.id, purchaseID: holding.id,
            weightGrams: 1, proceeds: Money(currency: .usd, minorUnits: 50), date: date,
            destinationAccountID: cash.id)
        var saved = try XCTUnwrap(data.accounts[0].tracking?.metalPurchases.first)
        XCTAssertEqual(saved.sales[0].cost.minorUnits, 33)
        XCTAssertEqual(saved.sales[0].gain.minorUnits, 17)
        XCTAssertEqual(saved.remainingWeightGrams, 2)
        XCTAssertEqual(saved.remainingCost.minorUnits, 67)
        XCTAssertEqual(LedgerIndex(data: data).balance(for: data.accounts[0]).minorUnits, 67)
        XCTAssertEqual(LedgerIndex(data: data).balance(for: cash).minorUnits, 50)
        data = try FinanceAssetTracking.sell(in: data, accountID: asset.id, purchaseID: holding.id,
            weightGrams: 2, proceeds: Money(currency: .usd, minorUnits: 40), date: date,
            destinationAccountID: cash.id)
        saved = try XCTUnwrap(data.accounts[0].tracking?.metalPurchases.first)
        XCTAssertEqual(saved.sales[1].cost.minorUnits, 67)
        XCTAssertEqual(saved.sales[1].gain.minorUnits, -27)
        XCTAssertEqual(saved.remainingCost.minorUnits, 0)
        XCTAssertEqual(saved.remainingQuantity, 0)
        XCTAssertEqual(LedgerIndex(data: data).balance(for: data.accounts[0]).minorUnits, 0)
        XCTAssertEqual(LedgerIndex(data: data).balance(for: cash).minorUnits, 90)
        let undone = try FinanceAssetTracking.undoLatest(in: data, accountID: asset.id)
        XCTAssertEqual(undone.accounts[0].tracking?.metalPurchases[0].remainingCost.minorUnits, 67)
        XCTAssertEqual(LedgerIndex(data: undone).balance(for: cash).minorUnits, 50)
        XCTAssertEqual(undone.transactions.count, 2)
    }

    func testMultipleHoldingsUsePureWeightAndReplaceRecordedContribution() throws {
        let asset = account(.physicalAsset)
        let initial = FinanceData(accounts: [asset], categories: [], transactions: [])
        var data = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: purchase(weight: 10, cost: 10_000, purity: Decimal(string: "0.75")!),
            fundingAccountID: nil, reconcileOpeningBalance: false)
        data = try FinanceAssetTracking.addPurchase(in: data, accountID: asset.id,
            purchase: purchase(weight: 5, cost: 5_000), fundingAccountID: nil, reconcileOpeningBalance: false)
        data.accounts[0].tracking?.metalPricing = [MetalPriceSetting(metal: .gold, mode: .manual,
            manualPricePerGram: 20, asOf: date)]
        let index = LedgerIndex(data: data)
        XCTAssertEqual(index.balance(for: data.accounts[0]).minorUnits, 15_000)
        XCTAssertEqual(index.valuation(for: data.accounts[0]).minorUnits, 25_000)
        XCTAssertEqual(index.assetValuationBalance(for: .usd).minorUnits, 25_000)
        XCTAssertEqual(index.availableBalance(for: .usd).minorUnits, 25_000)
        data.accounts[0].includeInTotals = false
        XCTAssertEqual(LedgerIndex(data: data).assetValuationBalance(for: .usd).minorUnits, 0)
    }

    func testInvestmentUpdatesReplaceAndRealizationsPreserveValuationAndDates() throws {
        for sign in [Int64(1), -1] {
            let investment = account(.investment, balance: 1_000_000)
            let initial = FinanceData(accounts: [investment], categories: [], transactions: [])
            XCTAssertThrowsError(try FinanceAssetTracking.updateInvestment(in: initial,
                accountID: investment.id, amount: Money(currency: .usd, minorUnits: sign * 50_000),
                date: date, confirmRecordedBalance: false))
            var data = try FinanceAssetTracking.updateInvestment(in: initial, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: sign * 10_000), date: date,
                confirmRecordedBalance: true)
            let cleared = try FinanceAssetTracking.undoLatest(in: data, accountID: investment.id)
            XCTAssertThrowsError(try FinanceAssetTracking.updateInvestment(in: cleared, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: sign * 10_000), date: date,
                confirmRecordedBalance: false))
            data = try FinanceAssetTracking.updateInvestment(in: data, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: sign * 50_000), date: date,
                confirmRecordedBalance: false)
            let valuationDate = try XCTUnwrap(data.accounts[0].tracking?.lastValuation)
            XCTAssertEqual(data.accounts[0].tracking?.unrealizedMinorUnits, sign * 50_000)
            let expectedTotal = 1_000_000 + sign * 50_000
            let beforeRealization = data
            data = try FinanceAssetTracking.realizeInvestment(in: data, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: sign * 20_000), date: date.addingTimeInterval(60))
            XCTAssertEqual(LedgerIndex(data: data).balance(for: data.accounts[0]).minorUnits, 1_000_000 + sign * 20_000)
            XCTAssertEqual(data.accounts[0].tracking?.unrealizedMinorUnits, sign * 30_000)
            XCTAssertEqual(LedgerIndex(data: data).valuation(for: data.accounts[0]).minorUnits, expectedTotal)
            XCTAssertEqual(data.accounts[0].tracking?.lastValuation, valuationDate)
            XCTAssertNil(FinanceAssetTracking.validationError(in: data))
            let undo = try FinanceAssetTracking.undoLatest(in: data, accountID: investment.id)
            XCTAssertEqual(undo.accounts, beforeRealization.accounts)
            XCTAssertEqual(undo.transactions, beforeRealization.transactions)
            XCTAssertThrowsError(try FinanceAssetTracking.realizeInvestment(in: data, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: sign * 30_001), date: date.addingTimeInterval(60)))
            XCTAssertThrowsError(try FinanceAssetTracking.realizeInvestment(in: data, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: -sign), date: date.addingTimeInterval(60)))
            data = try FinanceAssetTracking.realizeInvestment(in: data, accountID: investment.id,
                amount: Money(currency: .usd, minorUnits: sign * 30_000), date: date.addingTimeInterval(60))
            XCTAssertEqual(data.accounts[0].tracking?.unrealizedMinorUnits, 0)
            XCTAssertEqual(LedgerIndex(data: data).valuation(for: data.accounts[0]).minorUnits, expectedTotal)
            XCTAssertEqual(data.accounts[0].tracking?.lastValuation, valuationDate)
        }
    }

    func testAutomaticQuoteConversionManualOverrideAndMissingPrices() throws {
        var asset = account(.physicalAsset, currency: .eur)
        var data = FinanceData(accounts: [asset], categories: [], transactions: [])
        let quote = MetalQuote(metal: .gold,
            usdPricePerTroyOunce: MetalWeightUnit.troyOunces.gramsPerUnit * 100,
            marketDate: date, fetchedAt: date, nextRefreshAt: date.addingTimeInterval(60))
        data.metalQuotes = [quote]
        XCTAssertNil(FinanceAssetTracking.pricePerGram(account: asset, metal: .gold, data: data))
        data.exchangeRates = [ExchangeRate(baseCurrency: .usd, quoteCurrency: .eur, quoteUnitsPerBaseUnit: 2)]
        XCTAssertEqual(FinanceAssetTracking.pricePerGram(account: asset, metal: .gold, data: data), 200)
        data.exchangeRates = [ExchangeRate(baseCurrency: .eur, quoteCurrency: .usd, quoteUnitsPerBaseUnit: 2)]
        XCTAssertEqual(FinanceAssetTracking.pricePerGram(account: asset, metal: .gold, data: data), 50)
        asset.tracking = AccountTracking(metalPricing: [MetalPriceSetting(metal: .gold,
            mode: .manual, manualPricePerGram: 75, asOf: date)])
        XCTAssertEqual(FinanceAssetTracking.pricePerGram(account: asset, metal: .gold, data: data), 75)
        for invalid in [Decimal.zero, Decimal(-1), Decimal.nan] {
            asset.tracking?.metalPricing[0].manualPricePerGram = invalid
            XCTAssertNil(FinanceAssetTracking.pricePerGram(account: asset, metal: .gold, data: data))
        }
        let usdAsset = account(.physicalAsset)
        let initial = FinanceData(accounts: [usdAsset], categories: [], transactions: [])
        let added = try FinanceAssetTracking.addPurchase(in: initial, accountID: usdAsset.id,
            purchase: purchase(cost: 123), fundingAccountID: nil, reconcileOpeningBalance: false)
        XCTAssertEqual(LedgerIndex(data: added).valuation(for: added.accounts[0]).minorUnits, 123)
    }

    func testRejectsInvalidAmountsWeightsPurityAndSales() throws {
        XCTAssertEqual(try FinanceAssetTracking.money(Decimal(string: "1.005")!, currency: .usd).minorUnits, 101)
        XCTAssertThrowsError(try FinanceAssetTracking.money(.nan, currency: .usd))
        XCTAssertThrowsError(try FinanceAssetTracking.money(Decimal(Int64.max), currency: .usd))
        let asset = account(.physicalAsset)
        let cash = account(.cash)
        let initial = FinanceData(accounts: [asset, cash], categories: [], transactions: [])
        for invalid in [purchase(weight: 0), purchase(weight: -1), purchase(weight: .nan),
                        purchase(cost: 0), purchase(purity: 0), purchase(purity: 2), purchase(quantity: .nan)] {
            XCTAssertThrowsError(try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
                purchase: invalid, fundingAccountID: nil, reconcileOpeningBalance: false))
        }
        let holding = purchase()
        let data = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: holding, fundingAccountID: nil, reconcileOpeningBalance: false)
        for weight in [Decimal.zero, Decimal(-1), Decimal(4), Decimal.nan] {
            XCTAssertThrowsError(try FinanceAssetTracking.sell(in: data, accountID: asset.id,
                purchaseID: holding.id, weightGrams: weight, proceeds: Money(currency: .usd, minorUnits: 100),
                date: date, destinationAccountID: cash.id))
        }
        XCTAssertThrowsError(try FinanceAssetTracking.sell(in: data, accountID: asset.id,
            purchaseID: holding.id, weightGrams: 1, proceeds: Money(currency: .eur, minorUnits: 100),
            date: date, destinationAccountID: cash.id))
    }

    func testOldSavesDecodeWithoutTrackingAndQuotesAndNewDataRoundTrips() throws {
        let asset = account(.physicalAsset)
        let initial = FinanceData(accounts: [asset], categories: [], transactions: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        object.removeValue(forKey: "metalQuotes")
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        accounts[0].removeValue(forKey: "tracking")
        object["accounts"] = accounts
        let old = try JSONDecoder().decode(FinanceData.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.accounts[0].tracking)
        XCTAssertTrue(old.metalQuotes.isEmpty)
        var data = try FinanceAssetTracking.addPurchase(in: old, accountID: asset.id,
            purchase: purchase(), fundingAccountID: nil, reconcileOpeningBalance: false)
        data.metalQuotes = [MetalQuote(metal: .silver, usdPricePerTroyOunce: 30,
            marketDate: date, fetchedAt: date, nextRefreshAt: date.addingTimeInterval(60))]
        let decoded = try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded, data)
    }

    func testValidationRejectsMetalBalanceTamperingAndMissingLinkedActivity() throws {
        let asset = account(.physicalAsset)
        let cash = account(.cash, balance: 50_000)
        let initial = FinanceData(accounts: [asset, cash], categories: [], transactions: [])
        let data = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: purchase(cost: 10_000), fundingAccountID: cash.id, reconcileOpeningBalance: false)
        XCTAssertNil(FinanceAssetTracking.validationError(in: data))
        var missing = data
        missing.transactions.removeAll()
        XCTAssertNotNil(FinanceAssetTracking.validationError(in: missing))
        var tampered = data
        tampered.accounts[0].openingBalance = Money(currency: .usd, minorUnits: 1)
        XCTAssertNotNil(FinanceAssetTracking.validationError(in: tampered))
        XCTAssertNotNil(FinanceDataValidator.validate(tampered))
        var malformed = data
        malformed.accounts[0].tracking?.metalPurchases[0].purity = 2
        XCTAssertNotNil(FinanceAssetTracking.validationError(in: malformed))
    }

    func testValidationRejectsAlteredRealizationAndUnrealizedHistory() throws {
        let investment = account(.investment, balance: 100_000)
        let initial = FinanceData(accounts: [investment], categories: [], transactions: [])
        let valued = try FinanceAssetTracking.updateInvestment(in: initial, accountID: investment.id,
            amount: Money(currency: .usd, minorUnits: 5_000), date: date, confirmRecordedBalance: true)
        let realized = try FinanceAssetTracking.realizeInvestment(in: valued, accountID: investment.id,
            amount: Money(currency: .usd, minorUnits: 2_000), date: date)
        XCTAssertNil(FinanceAssetTracking.validationError(in: realized))
        var altered = realized
        altered.transactions[0].inflows[0].money = Money(currency: .usd, minorUnits: 2_001)
        XCTAssertNotNil(FinanceAssetTracking.validationError(in: altered))
        var brokenHistory = realized
        brokenHistory.accounts[0].tracking?.investmentEntries[1].previousUnrealizedMinorUnits = 4_999
        XCTAssertNotNil(FinanceAssetTracking.validationError(in: brokenHistory))
        var missing = realized
        missing.transactions.removeAll()
        XCTAssertNotNil(FinanceAssetTracking.validationError(in: missing))
    }

    func testDateOnlySalesAndRealizationsAllowEarlierTimeOnSameDay() throws {
        let day = Calendar.current.startOfDay(for: date)
        let asset = account(.physicalAsset)
        let cash = account(.cash)
        var holding = purchase()
        holding.date = day.addingTimeInterval(3_600)
        let initial = FinanceData(accounts: [asset, cash], categories: [], transactions: [])
        let added = try FinanceAssetTracking.addPurchase(in: initial, accountID: asset.id,
            purchase: holding, fundingAccountID: nil, reconcileOpeningBalance: false)
        XCTAssertNoThrow(try FinanceAssetTracking.sell(in: added, accountID: asset.id,
            purchaseID: holding.id, weightGrams: 1, proceeds: Money(currency: .usd, minorUnits: 40),
            date: day, destinationAccountID: cash.id))
        let investment = account(.investment)
        let valued = try FinanceAssetTracking.updateInvestment(
            in: FinanceData(accounts: [investment], categories: [], transactions: []),
            accountID: investment.id, amount: Money(currency: .usd, minorUnits: 500),
            date: day.addingTimeInterval(3_600), confirmRecordedBalance: true)
        XCTAssertNoThrow(try FinanceAssetTracking.realizeInvestment(in: valued,
            accountID: investment.id, amount: Money(currency: .usd, minorUnits: 100), date: day))
    }
}
