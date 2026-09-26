import XCTest
@testable import FinanceDemo

final class FinanceModelTests: XCTestCase {
    func testLedgerIndexAndMetricsSnapshotPreserveFilteredTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 15)))
        let march = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        let yearInterval = try XCTUnwrap(calendar.dateInterval(of: .year, for: january))
        let januaryInterval = try XCTUnwrap(calendar.dateInterval(of: .month, for: january))
        let februaryInterval = try XCTUnwrap(calendar.dateInterval(of: .month, for: february))

        let cash = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 10_000)
        )
        let excludedCash = Account(
            name: "Excluded cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 20_000),
            includeInTotals: false
        )
        let living = LedgerCategory(name: "Living")
        let food = LedgerCategory(name: "Food", parentID: living.id)
        let excludedRoot = LedgerCategory(name: "Modified Bal.", includeInTotals: true)
        let excludedChild = LedgerCategory(name: "Adjustments", parentID: excludedRoot.id)

        func expense(
            _ date: Date,
            _ amount: Int64,
            categoryID: UUID?,
            accountID: UUID? = nil,
            returned: Int64 = 0
        ) -> LedgerTransaction {
            LedgerTransaction(
                date: date,
                note: "Expense",
                kind: .expense,
                categoryID: categoryID,
                outflows: [
                    MoneyMovement(
                        accountID: accountID ?? cash.id,
                        money: Money(currency: .usd, minorUnits: amount)
                    )
                ],
                inflows: returned == 0
                    ? []
                    : [
                        MoneyMovement(
                            accountID: accountID ?? cash.id,
                            money: Money(currency: .usd, minorUnits: returned)
                        )
                    ]
            )
        }

        let transactions = [
            expense(january, 1_000, categoryID: food.id),
            expense(february, 2_000, categoryID: food.id, returned: 500),
            expense(february, 4_000, categoryID: excludedChild.id),
            expense(february, 7_000, categoryID: food.id, accountID: excludedCash.id),
            LedgerTransaction(
                date: march,
                note: "Salary",
                kind: .income,
                categoryID: nil,
                outflows: [],
                inflows: [
                    MoneyMovement(
                        accountID: cash.id,
                        money: Money(currency: .usd, minorUnits: 3_000)
                    )
                ]
            )
        ]
        let data = FinanceData(
            accounts: [cash, excludedCash],
            categories: [living, food, excludedRoot, excludedChild],
            transactions: transactions
        )
        let index = LedgerIndex(data: data, calendar: calendar)

        XCTAssertEqual(index.categoryPath(for: food.id), "Living / Food")
        XCTAssertFalse(index.categoryIncludedInTotals(excludedChild.id))
        XCTAssertEqual(index.sortedTransactions.first?.date, march)
        XCTAssertEqual(index.balance(for: cash).minorUnits, 6_500)
        XCTAssertEqual(index.availableBalance(for: .usd).minorUnits, 6_500)
        XCTAssertEqual(index.monthlyExpenseTotals(for: february, calendar: calendar)[.usd], 1_500)

        let month = MetricsSnapshot.make(
            index: index,
            interval: februaryInterval,
            selectedCurrency: .usd,
            selectedCategoryID: living.id
        )
        XCTAssertEqual(month.expenses, 1_500)
        XCTAssertEqual(month.income, 0)
        XCTAssertEqual(month.filteredTransactions.count, 1)
        XCTAssertEqual(month.categories.first?.amount, 1_500)
        XCTAssertEqual(month.categories.first?.title, "Living")
        XCTAssertEqual(month.accounts.first?.title, "Cash")
        XCTAssertEqual(month.accounts.first?.amount, 1_500)
        XCTAssertEqual(month.activityCounts[.expense], 1)

        let februarySubcategories = MetricsSnapshot.subcategoryBreakdown(
            index: index,
            categoryID: living.id,
            interval: februaryInterval,
            selectedCurrency: .usd
        )
        XCTAssertEqual(februarySubcategories.first?.title, "Food")
        XCTAssertEqual(februarySubcategories.first?.amount, 1_500)

        let year = MetricsSnapshot.make(
            index: index,
            interval: yearInterval,
            selectedCurrency: .usd,
            selectedCategoryID: nil
        )
        XCTAssertEqual(year.expenses, 2_500)
        XCTAssertEqual(year.income, 3_000)
        XCTAssertEqual(year.activityCounts[.expense], 2)
        XCTAssertEqual(year.activityCounts[.income], 1)

        let exchangeRate = ExchangeRate(
            baseCurrency: .usd,
            quoteCurrency: .eur,
            quoteUnitsPerBaseUnit: try XCTUnwrap(Decimal(string: "0.9"))
        )
        let convertedTransaction = LedgerTransaction(
            date: january,
            note: "Converted expense",
            kind: .expense,
            categoryID: food.id,
            outflows: [
                MoneyMovement(
                    accountID: cash.id,
                    money: Money(currency: .usd, minorUnits: 1_000)
                )
            ],
            inflows: [],
            exchangeRate: exchangeRate
        )
        let currencyIndex = LedgerIndex(
            data: FinanceData(
                accounts: [cash],
                categories: [living, food],
                transactions: [convertedTransaction]
            ),
            calendar: calendar
        )
        let euroMetrics = MetricsSnapshot.make(
            index: currencyIndex,
            interval: januaryInterval,
            selectedCurrency: .eur,
            selectedCategoryID: living.id
        )
        XCTAssertEqual(euroMetrics.expenses, 900)

        let budget = LedgerBudget(
            categoryID: food.id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 5_000),
            rollover: true,
            startedAt: january
        )
        XCTAssertEqual(index.budgetSpent(budget, interval: februaryInterval, calendar: calendar).minorUnits, 1_500)
        XCTAssertEqual(
            financeBudgetAllowance(
                budget,
                in: data,
                interval: februaryInterval,
                using: index,
                calendar: calendar
            ).minorUnits,
            9_000
        )
        XCTAssertEqual(index.budgetSpent(budget, interval: januaryInterval, calendar: calendar).minorUnits, 1_000)
    }

    func testMetricsSnapshotBenchmarkUsesOneAggregatedPass() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let account = Account(
            name: "Benchmark cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let category = LedgerCategory(name: "Benchmark")
        let transactions = (0..<2_000).map { index in
            LedgerTransaction(
                date: calendar.date(byAdding: .day, value: index % 365, to: date) ?? date,
                note: "Benchmark \(index)",
                kind: .expense,
                categoryID: category.id,
                outflows: [
                    MoneyMovement(
                        accountID: account.id,
                        money: Money(currency: .usd, minorUnits: Int64(index + 1))
                    )
                ],
                inflows: []
            )
        }
        let index = LedgerIndex(
            data: FinanceData(accounts: [account], categories: [category], transactions: transactions),
            calendar: calendar
        )
        let interval = try XCTUnwrap(calendar.dateInterval(of: .year, for: date))

        measure {
            _ = MetricsSnapshot.make(
                index: index,
                interval: interval,
                selectedCurrency: .usd,
                selectedCategoryID: nil
            )
        }
    }

    func testMetricsReportWritesExistingShareablePDF() throws {
        let report = MetricsReportData(
            periodTitle: "September 2026",
            dateRange: "Sep 1, 2026 – Sep 30, 2026",
            currency: .usd,
            categoryScope: "All categories",
            income: Money(currency: .usd, minorUnits: 0),
            expenses: Money(currency: .usd, minorUnits: 0),
            entryCount: 0,
            activityCounts: [:],
            categories: [],
            generatedAt: .now
        )

        let url = try MetricsReportPDF.writeShareableFile(for: report)
        defer { try? FileManager.default.removeItem(at: url) }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
    }

    func testLegacyModelFieldsDecodeToSafeDefaults() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let category = LedgerCategory(name: "Food")
        let transaction = LedgerTransaction(
            note: "Coffee",
            kind: .expense,
            categoryID: category.id,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 500)
                )
            ],
            inflows: []
        )
        let encoded = try JSONEncoder().encode(
            FinanceData(accounts: [account], categories: [category], transactions: [transaction])
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attachments")
        object.removeValue(forKey: "attentionState")
        object.removeValue(forKey: "reconciliations")
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        accounts[0].removeValue(forKey: "isArchived")
        object["accounts"] = accounts
        var categories = try XCTUnwrap(object["categories"] as? [[String: Any]])
        categories[0].removeValue(forKey: "isArchived")
        object["categories"] = categories
        var transactions = try XCTUnwrap(object["transactions"] as? [[String: Any]])
        transactions[0].removeValue(forKey: "attachmentIDs")
        object["transactions"] = transactions

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FinanceData.self, from: legacyData)

        XCTAssertFalse(decoded.accounts[0].isArchived)
        XCTAssertFalse(decoded.categories[0].isArchived)
        XCTAssertEqual(decoded.transactions[0].attachmentIDs, [])
        XCTAssertEqual(decoded.attachments, [])
        XCTAssertEqual(decoded.attentionState.dismissedIDs, [])
        XCTAssertEqual(decoded.reconciliations, [:])
    }

    func testAttentionStateRoundTripsWithFinanceData() throws {
        let data = FinanceData(
            accounts: [],
            categories: [],
            transactions: [],
            attentionState: FinanceAttentionState(
                dismissedIDs: ["over-budget", "uncategorized-expenses"]
            )
        )

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(FinanceData.self, from: encoded)

        XCTAssertEqual(decoded.attentionState.dismissedIDs, data.attentionState.dismissedIDs)
    }

    func testReconciliationStateRoundTripsWithFinanceData() throws {
        let accountID = UUID()
        let reconciliation = AccountReconciliation(
            lastReconciledAt: Date(timeIntervalSince1970: 1_700_000_000),
            difference: Money(currency: .usd, minorUnits: 125)
        )
        let data = FinanceData(
            accounts: [],
            categories: [],
            transactions: [],
            reconciliations: [accountID: reconciliation]
        )

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(FinanceData.self, from: encoded)

        XCTAssertEqual(decoded.reconciliations[accountID], reconciliation)
    }

    func testSameCurrencyTransferMustBalance() {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let destination = Account(
            name: "Bank",
            type: .bankAccount,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let transaction = LedgerTransaction(
            note: "Unbalanced",
            kind: .transfer,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 100))],
            inflows: [MoneyMovement(accountID: destination.id, money: Money(currency: .usd, minorUnits: 90))]
        )
        let data = FinanceData(accounts: [account, destination], categories: [], transactions: [])

        XCTAssertEqual(
            FinanceTransactionValidator.validate(transaction, in: data),
            .unbalancedTransfer
        )
    }

    func testArchivedAccountsCannotBeUsedForNewTransactions() {
        let account = Account(
            name: "Old cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0),
            isArchived: true
        )
        let transaction = LedgerTransaction(
            note: "Expense",
            kind: .expense,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 100))],
            inflows: []
        )
        let data = FinanceData(accounts: [account], categories: [], transactions: [])

        XCTAssertEqual(
            FinanceTransactionValidator.validate(transaction, in: data),
            .archivedMovementAccount
        )
    }

    func testMissingAttachmentReferenceIsRejected() {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let transaction = LedgerTransaction(
            note: "Receipt",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 100)
                )
            ],
            inflows: [],
            attachmentIDs: [UUID()]
        )
        let data = FinanceData(accounts: [account], categories: [], transactions: [])

        XCTAssertEqual(
            FinanceTransactionValidator.validate(transaction, in: data),
            .missingAttachment
        )
    }

    func testDataValidatorRejectsMissingTransactionAccount() {
        let transaction = LedgerTransaction(
            note: "Broken import",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: UUID(),
                    money: Money(currency: .usd, minorUnits: 100)
                )
            ],
            inflows: []
        )
        let data = FinanceData(accounts: [], categories: [], transactions: [transaction])

        XCTAssertEqual(
            FinanceDataValidator.validate(data),
            .invalidTransaction(index: 0, error: .missingMovementAccount)
        )
    }

    func testDataValidatorRejectsCategoryCyclesAndDuplicateIDs() {
        let categoryID = UUID()
        let first = LedgerCategory(id: categoryID, name: "First", parentID: nil)
        let second = LedgerCategory(name: "Second", parentID: categoryID)
        var cyclicFirst = first
        cyclicFirst.parentID = second.id
        let cyclicData = FinanceData(
            accounts: [],
            categories: [cyclicFirst, second],
            transactions: []
        )

        XCTAssertEqual(
            FinanceDataValidator.validate(cyclicData),
            .categoryCycle("First")
        )

        let duplicate = LedgerCategory(id: categoryID, name: "Duplicate")
        let duplicateData = FinanceData(
            accounts: [],
            categories: [first, duplicate],
            transactions: []
        )
        XCTAssertEqual(
            FinanceDataValidator.validate(duplicateData),
            .duplicateIDs("categories")
        )
    }

    func testExpenseSpendingSubtractsReturnedMoney() {
        let category = LedgerCategory(name: "Food")
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 5_000)
        )
        let transaction = LedgerTransaction(
            note: "Lunch",
            kind: .expense,
            categoryID: category.id,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 2_000)
                )
            ],
            inflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 500)
                )
            ]
        )
        let data = FinanceData(
            accounts: [account],
            categories: [category],
            transactions: [transaction]
        )

        XCTAssertEqual(
            financeNetExpenseAmount(transaction, currency: .usd, in: data),
            1_500
        )
        let budget = LedgerBudget(
            categoryID: category.id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 5_000)
        )
        XCTAssertEqual(financeBudgetSpent(budget, in: data).minorUnits, 1_500)
    }

    func testExcludedCategoryDoesNotCountInExpenseTotals() {
        let category = LedgerCategory(name: "Modified balance", includeInTotals: false)
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let transaction = LedgerTransaction(
            note: "Adjustment",
            kind: .expense,
            categoryID: category.id,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 1_000))],
            inflows: []
        )
        let data = FinanceData(accounts: [account], categories: [category], transactions: [transaction])

        XCTAssertEqual(financeNetExpenseAmount(transaction, currency: .usd, in: data), 0)
    }

    func testBackupBundleRoundTripsAttachmentBytes() throws {
        let attachment = LedgerAttachment(
            fileName: "receipt.jpg",
            contentType: "image/jpeg",
            relativePath: "receipt-id.jpg"
        )
        let data = FinanceData(
            accounts: [],
            categories: [],
            transactions: [],
            attachments: [attachment]
        )
        let bytes = Data([0x01, 0x02, 0x03])

        let encoded = try LedgerBackupCodec.encodeBundle(
            data,
            attachmentData: [attachment.id: bytes]
        )
        let decoded = try LedgerBackupCodec.decodeBundle(encoded)

        let decodedAttachment = try XCTUnwrap(decoded.data.attachments.first)
        XCTAssertEqual(decodedAttachment.id, attachment.id)
        XCTAssertEqual(decodedAttachment.fileName, attachment.fileName)
        XCTAssertEqual(decodedAttachment.contentType, attachment.contentType)
        XCTAssertEqual(decodedAttachment.relativePath, attachment.relativePath)
        XCTAssertEqual(decoded.attachments.first?.data, bytes)
    }

    func testUnsupportedBackupBundleVersionIsRejected() throws {
        let encoded = try LedgerBackupCodec.encodeBundle(
            FinanceData(accounts: [], categories: [], transactions: []),
            attachmentData: [:]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try LedgerBackupCodec.decodeBundle(unsupported))
        XCTAssertThrowsError(try LedgerBackupCodec.decodeBundle(Data("not a backup".utf8)))
    }

    func testMoneyParsingUsesCurrencyMinorUnits() {
        XCTAssertEqual(
            Money.parse("12.50", currency: .usd, locale: Locale(identifier: "en_US_POSIX")),
            .some(Money(currency: .usd, minorUnits: 1_250))
        )
        XCTAssertEqual(
            Money.parse("125000", currency: .lbp, locale: Locale(identifier: "en_US_POSIX")),
            .some(Money(currency: .lbp, minorUnits: 125_000))
        )
    }

    func testMoneyDisplayFormattingIsLocaleAwareAndExportsRemainStable() {
        let money = Money(currency: .usd, minorUnits: 1_250)

        XCTAssertTrue(
            money.formatted(locale: Locale(identifier: "en_US_POSIX")).contains("12.50")
        )
        XCTAssertTrue(
            money.formatted(locale: Locale(identifier: "de_DE")).contains(",50")
        )
        XCTAssertEqual(money.stableFormatted, "$12.50")
        XCTAssertEqual(
            Money.parse("1.234,50", currency: .usd, locale: Locale(identifier: "de_DE")),
            Money(currency: .usd, minorUnits: 123_450)
        )
    }

    func testCurrencyInputFormattingUsesGroupingAndCurrencyFractionDigits() {
        let locale = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(
            LedgerCurrency.usd.formattedInput("858464886", locale: locale),
            "858,464,886.00"
        )
        XCTAssertEqual(
            LedgerCurrency.lbp.formattedInput("858464886", locale: locale),
            "858,464,886"
        )
        XCTAssertEqual(
            LedgerCurrency.eur.formattedInput("12.5", locale: locale),
            "12.50"
        )
        XCTAssertEqual(LedgerCurrency.usd.formattedInput("", locale: locale), "")
    }

    func testMoneyRecastPreservesDisplayedNumericAmount() {
        XCTAssertEqual(
            Money(currency: .usd, minorUnits: 1_000).recast(to: .lbp),
            Money(currency: .lbp, minorUnits: 10)
        )
        XCTAssertEqual(
            Money(currency: .lbp, minorUnits: 10).recast(to: .usd),
            Money(currency: .usd, minorUnits: 1_000)
        )
    }

    func testImportInfersCurrencyAndAccountTypeFromAccountName() throws {
        let table = ImportedTable(
            id: "accounts",
            name: "Accounts",
            columns: ["Date", "Amount", "Account"],
            rows: [["2026-09-06", "10", "EUR Savings"]]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: nil,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: FinanceData(accounts: [], categories: [], transactions: [])
        )

        let account = try XCTUnwrap(result.data.accounts.first)
        XCTAssertEqual(account.currency, .eur)
        XCTAssertEqual(account.type, .bankAccount)
    }

    func testImportInfersPreciousMetalAccountsAsPhysicalAssets() throws {
        let table = ImportedTable(
            id: "assets",
            name: "Assets",
            columns: ["Date", "Amount", "Account", "Account Type"],
            rows: [
                ["2026-09-06", "10", "Gold", "Good"],
                ["2026-09-07", "20", "Silver coins", "Silver"]
            ]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: nil,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true,
                accountSuggestions: [
                    ImportAccountCandidate.key(for: "Gold"): ImportAccountSuggestion(
                        type: .investment,
                        currency: .usd
                    ),
                    ImportAccountCandidate.key(for: "Silver coins"): ImportAccountSuggestion(
                        type: .bankAccount,
                        currency: .usd
                    )
                ]
            ),
            existing: FinanceData(accounts: [], categories: [], transactions: [])
        )

        let accountTypes = Dictionary(uniqueKeysWithValues: result.data.accounts.map { ($0.name, $0.type) })
        XCTAssertEqual(accountTypes["Gold"], .physicalAsset)
        XCTAssertEqual(accountTypes["Silver coins"], .physicalAsset)
    }

    func testImportUsesAccountSuggestionWhenMappedValuesAreMissing() throws {
        let table = ImportedTable(
            id: "accounts",
            name: "Accounts",
            columns: ["Date", "Amount", "Account"],
            rows: [["2026-09-06", "10", "Emergency Reserve"]]
        )
        let accountName = "Emergency Reserve"

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: nil,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true,
                accountSuggestions: [
                    ImportAccountCandidate.key(for: accountName): ImportAccountSuggestion(
                        type: .bankAccount,
                        currency: .eur
                    )
                ]
            ),
            existing: FinanceData(accounts: [], categories: [], transactions: [])
        )

        let account = try XCTUnwrap(result.data.accounts.first)
        XCTAssertEqual(account.name, accountName)
        XCTAssertEqual(account.type, .bankAccount)
        XCTAssertEqual(account.currency, .eur)
        XCTAssertEqual(
            result.data.transactions.first?.outflows.first?.money,
            Money(currency: .eur, minorUnits: 1_000)
        )
    }

    func testImportExplicitAccountValuesOverrideAccountSuggestion() throws {
        let table = ImportedTable(
            id: "accounts",
            name: "Accounts",
            columns: ["Date", "Amount", "Account", "Currency", "Account Type"],
            rows: [["2026-09-06", "10", "Emergency Reserve", "LBP", "Cash"]]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: nil,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true,
                accountSuggestions: [
                    ImportAccountCandidate.key(for: "Emergency Reserve"): ImportAccountSuggestion(
                        type: .loan,
                        currency: .eur
                    )
                ]
            ),
            existing: FinanceData(accounts: [], categories: [], transactions: [])
        )

        let account = try XCTUnwrap(result.data.accounts.first)
        XCTAssertEqual(account.type, .cash)
        XCTAssertEqual(account.currency, .lbp)
    }

    func testImportAccountCandidatesCombineSourceAndDestinationAccountsForOneBatch() {
        let table = ImportedTable(
            id: "transfers",
            name: "Transfers",
            columns: [
                "Date", "Amount", "Account", "Destination Account",
                "Currency", "Destination Currency", "Account Type", "Destination Account Type"
            ],
            rows: [
                ["2026-09-06", "10", "Wallet", "Savings", "USD", "EUR", "Cash", "Bank account"],
                ["2026-09-07", "15", "wallet", "Savings", "USD", "EUR", "Cash", "Bank account"]
            ]
        )
        let mapping: [ImportField: String?] = [
            .account: "Account",
            .destinationAccount: "Destination Account",
            .currency: "Currency",
            .destinationCurrency: "Destination Currency",
            .accountType: "Account Type",
            .destinationAccountType: "Destination Account Type"
        ]

        let candidates = FinanceImportBuilder.accountImportCandidates(
            table: table,
            mapping: mapping
        )

        XCTAssertEqual(candidates.map(\.name), ["Savings", "Wallet"])
        XCTAssertEqual(candidates.first { ImportAccountCandidate.key(for: $0.name) == "wallet" }?.observedCurrencies, ["USD"])
        XCTAssertEqual(candidates.first { ImportAccountCandidate.key(for: $0.name) == "savings" }?.observedCurrencies, ["EUR"])
    }

    func testImportReusesMatchingAccountNameBeforeCreatingDuplicate() throws {
        let account = Account(
            name: "Wallet",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        let table = ImportedTable(
            id: "accounts",
            name: "Accounts",
            columns: ["Date", "Amount", "Account"],
            rows: [["2026-09-06", "10", "Wallet"]]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: nil,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: FinanceData(accounts: [account], categories: [], transactions: [])
        )

        XCTAssertTrue(result.data.accounts.isEmpty)
        XCTAssertEqual(result.data.transactions.first?.outflows.first?.accountID, account.id)
        XCTAssertEqual(result.data.transactions.first?.outflows.first?.money, Money(currency: .lbp, minorUnits: 10))
    }

    func testAccountCurrencyMigrationUpdatesOpeningBalanceAndTransactions() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 1_000)
        )
        let transaction = LedgerTransaction(
            note: "Lunch",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 1_000)
                )
            ],
            inflows: []
        )

        let migrated = FinanceAccountCurrencyMigration.migrating(
            FinanceData(accounts: [account], categories: [], transactions: [transaction]),
            accountID: account.id,
            from: .usd,
            to: .lbp
        )

        XCTAssertEqual(migrated.accounts.first?.currency, .lbp)
        XCTAssertEqual(migrated.accounts.first?.openingBalance, Money(currency: .lbp, minorUnits: 10))
        XCTAssertEqual(
            migrated.transactions.first?.outflows.first?.money,
            Money(currency: .lbp, minorUnits: 10)
        )
        XCTAssertNil(FinanceDataValidator.validate(migrated))
    }

    func testAccountCurrencyMigrationUsesTransactionExchangeRate() throws {
        let account = Account(
            name: "LBP Cash",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        let rate = ExchangeRate(
            baseCurrency: .lbp,
            quoteCurrency: .usd,
            quoteUnitsPerBaseUnit: try XCTUnwrap(Decimal(string: "0.000073059"))
        )
        let transaction = LedgerTransaction(
            note: "January 3 expense",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .lbp, minorUnits: 273_750)
                )
            ],
            inflows: [],
            exchangeRate: rate
        )

        let migrated = FinanceAccountCurrencyMigration.migrating(
            FinanceData(accounts: [account], categories: [], transactions: [transaction]),
            accountID: account.id,
            from: .lbp,
            to: .usd
        )

        XCTAssertEqual(
            migrated.transactions.first?.outflows.first?.money,
            Money(currency: .usd, minorUnits: 2_000)
        )
        XCTAssertNil(migrated.transactions.first?.exchangeRate)
        XCTAssertEqual(
            financeNetExpenseAmount(
                try XCTUnwrap(migrated.transactions.first),
                currency: .usd,
                in: migrated
            ),
            2_000
        )
        XCTAssertNil(FinanceDataValidator.validate(migrated))
    }

    func testAccountCurrencyMigrationRepairsNegativeImportedMovement() throws {
        let account = Account(
            name: "LBP Cash",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        let rate = ExchangeRate(
            baseCurrency: .lbp,
            quoteCurrency: .usd,
            quoteUnitsPerBaseUnit: try XCTUnwrap(Decimal(string: "0.000073059"))
        )
        let transaction = LedgerTransaction(
            note: "Imported LBP expense",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .lbp, minorUnits: -273_750)
                )
            ],
            inflows: [],
            exchangeRate: rate
        )

        let migrated = FinanceAccountCurrencyMigration.migrating(
            FinanceData(accounts: [account], categories: [], transactions: [transaction]),
            accountID: account.id,
            from: .lbp,
            to: .usd
        )

        XCTAssertEqual(
            migrated.transactions.first?.outflows.first?.money,
            Money(currency: .usd, minorUnits: 2_000)
        )
        XCTAssertNil(FinanceDataValidator.validate(migrated))
    }

    func testAccountCurrencyMigrationPreservesForeignCurrencyMovements() throws {
        let account = Account(
            name: "USD Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let rate = ExchangeRate(
            baseCurrency: .lbp,
            quoteCurrency: .eur,
            quoteUnitsPerBaseUnit: try XCTUnwrap(Decimal(string: "0.0000105"))
        )
        let transaction = LedgerTransaction(
            note: "Foreign payment",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .lbp, minorUnits: 273_750)
                )
            ],
            inflows: [],
            exchangeRate: rate
        )

        let migrated = FinanceAccountCurrencyMigration.migrating(
            FinanceData(accounts: [account], categories: [], transactions: [transaction]),
            accountID: account.id,
            from: .usd,
            to: .eur
        )

        XCTAssertEqual(migrated.transactions.first?.outflows.first?.money, transaction.outflows.first?.money)
        XCTAssertEqual(migrated.transactions.first?.exchangeRate, rate)
        XCTAssertNil(FinanceDataValidator.validate(migrated))
    }

    func testImportReviewDropsUnusedCreatedRecordsAndKeepsCategoryAncestors() {
        let usedAccount = Account(
            name: "Imported cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let unusedAccount = Account(
            name: "Unused account",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let root = LedgerCategory(name: "Living")
        let child = LedgerCategory(name: "Food", parentID: root.id)
        let unusedCategory = LedgerCategory(name: "Unused")
        let transaction = LedgerTransaction(
            note: "Lunch",
            kind: .expense,
            categoryID: child.id,
            outflows: [
                MoneyMovement(
                    accountID: usedAccount.id,
                    money: Money(currency: .usd, minorUnits: 500)
                )
            ],
            inflows: []
        )

        let prepared = FinanceImportReview.removingUnusedCreatedRecords(
            from: FinanceData(
                accounts: [usedAccount, unusedAccount],
                categories: [root, child, unusedCategory],
                transactions: [transaction]
            )
        )

        XCTAssertEqual(prepared.accounts.map(\.id), [usedAccount.id])
        XCTAssertEqual(Set(prepared.categories.map(\.id)), Set([root.id, child.id]))
    }

    func testImportReviewKeepsExplicitlyArchivedUnreferencedAccounts() {
        let archivedAccount = Account(
            name: "Old gold account",
            type: .physicalAsset,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0),
            isArchived: true
        )
        let prepared = FinanceImportReview.removingUnusedCreatedRecords(
            from: FinanceData(accounts: [archivedAccount], categories: [], transactions: [])
        )

        XCTAssertEqual(prepared.accounts.map(\.id), [archivedAccount.id])
    }

    func testArchivedHistoricalAccountRemainsValidAndIsExcludedFromActiveChoices() {
        let archivedAccount = Account(
            name: "Historical silver",
            type: .physicalAsset,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0),
            isArchived: true
        )
        let transaction = LedgerTransaction(
            note: "Historical sale",
            kind: .income,
            categoryID: nil,
            outflows: [],
            inflows: [MoneyMovement(accountID: archivedAccount.id, money: Money(currency: .usd, minorUnits: 1_000))]
        )
        let data = FinanceData(accounts: [archivedAccount], categories: [], transactions: [transaction])

        XCTAssertNil(FinanceDataValidator.validate(data))
        XCTAssertNil(FinanceTransactionValidator.validate(transaction, in: data, allowArchivedReferences: true))
        XCTAssertTrue(data.accounts.filter { !$0.isArchived }.isEmpty)
    }

    func testImportWizardDraftPreservesStateAcrossStepsAndDiscardsStagedData() {
        let document = ImportedDocument(
            fileName: "ledger.csv",
            format: .delimited,
            tables: [
                ImportedTable(
                    id: "rows",
                    name: "Rows",
                    columns: ["Date", "Amount"],
                    rows: [["2026-09-01", "10"]]
                )
            ]
        )
        var draft = ImportDraft(
            document: document,
            existing: FinanceData(accounts: [], categories: [], transactions: []),
            rememberedRules: ImportStoredRules()
        )
        draft.setMapping(.date, to: "Date")
        draft.setMapping(.amount, to: "Amount")
        let mappingBeforeNavigation = draft.mapping
        draft.step = .defaults
        draft.step = .organize
        draft.step = .defaults

        XCTAssertEqual(draft.mapping, mappingBeforeNavigation)
        XCTAssertEqual(draft.step, .defaults)

        draft.importedData = FinanceData(accounts: [], categories: [], transactions: [])
        draft.discard()
        XCTAssertEqual(draft.step, .source)
        XCTAssertNil(draft.importedData)
        XCTAssertNil(draft.result)
    }

    func testImportWizardBulkAccountOperationsRecastArchiveAndMap() throws {
        let imported = Account(
            name: "Imported gold",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 1_000)
        )
        let target = Account(
            name: "Physical assets",
            type: .physicalAsset,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let transaction = LedgerTransaction(
            note: "Gold purchase",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: imported.id,
                    money: Money(currency: .usd, minorUnits: 500)
                )
            ],
            inflows: []
        )
        let document = ImportedDocument(
            fileName: "rows.csv",
            format: .delimited,
            tables: [ImportedTable(id: "rows", name: "Rows", columns: ["Date", "Amount"], rows: [])]
        )
        var draft = ImportDraft(
            document: document,
            existing: FinanceData(accounts: [target], categories: [], transactions: []),
            rememberedRules: ImportStoredRules()
        )
        draft.importedData = FinanceData(accounts: [imported], categories: [], transactions: [transaction])
        draft.selectedAccountIDs = [imported.id]

        _ = try draft.apply(.setType(.physicalAsset), existingAccounts: [target])
        _ = try draft.apply(.setCurrency(.eur), existingAccounts: [target])
        _ = try draft.apply(.setIncludeInTotals(false), existingAccounts: [target])
        _ = try draft.apply(.setArchived(true), existingAccounts: [target])

        let edited = try XCTUnwrap(draft.importedData?.accounts.first)
        XCTAssertEqual(edited.type, .physicalAsset)
        XCTAssertEqual(edited.currency, .eur)
        XCTAssertFalse(edited.includeInTotals)
        XCTAssertTrue(edited.isArchived)
        XCTAssertEqual(draft.importedData?.transactions.first?.outflows.first?.money.currency, .eur)

        var mappingDraft = draft
        mappingDraft.selectedAccountIDs = [imported.id]
        let usdImported = Account(
            id: imported.id,
            name: imported.name,
            type: imported.type,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 1_000)
        )
        mappingDraft.importedData = FinanceData(
            accounts: [usdImported],
            categories: [],
            transactions: [
                LedgerTransaction(
                    note: "Mapped",
                    kind: .expense,
                    categoryID: nil,
                    outflows: [MoneyMovement(accountID: imported.id, money: Money(currency: .usd, minorUnits: 500))],
                    inflows: []
                )
            ]
        )
        _ = try mappingDraft.apply(.mapToExisting(target.id), existingAccounts: [target])
        XCTAssertTrue(mappingDraft.importedData?.accounts.isEmpty == true)
        XCTAssertEqual(mappingDraft.importedData?.transactions.first?.outflows.first?.accountID, target.id)
        XCTAssertEqual(mappingDraft.remappedAccountCount, 1)

        let lbpImported = Account(
            name: "LBP account",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        mappingDraft.importedData?.accounts = [usdImported, lbpImported]
        mappingDraft.selectedAccountIDs = [lbpImported.id, usdImported.id]
        XCTAssertThrowsError(try mappingDraft.apply(.mapToExisting(target.id), existingAccounts: [target])) { error in
            XCTAssertEqual(error as? ImportBulkMutationError, .mixedCurrencies)
        }
    }

    func testImportWizardBulkCategoryOperationsAndCreationToggleException() throws {
        let provisional = LedgerCategory(name: "Eating out")
        let unused = LedgerCategory(name: "Unused")
        let existing = LedgerCategory(name: "Food")
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let transaction = LedgerTransaction(
            note: "Lunch",
            kind: .expense,
            categoryID: provisional.id,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 500))],
            inflows: []
        )
        let document = ImportedDocument(
            fileName: "rows.csv",
            format: .delimited,
            tables: [ImportedTable(id: "rows", name: "Rows", columns: ["Date", "Amount"], rows: [])]
        )
        var draft = ImportDraft(
            document: document,
            existing: FinanceData(accounts: [account], categories: [existing], transactions: []),
            rememberedRules: ImportStoredRules()
        )
        draft.importedData = FinanceData(
            accounts: [account],
            categories: [provisional, unused],
            transactions: [transaction]
        )
        draft.selectedCategoryIDs = [provisional.id]
        _ = try draft.apply(.mapToExisting(existing.id), existingCategories: [existing])
        XCTAssertEqual(draft.importedData?.transactions.first?.categoryID, existing.id)
        XCTAssertFalse(draft.importedData?.categories.contains(where: { $0.id == provisional.id }) == true)

        draft.selectedCategoryIDs = [unused.id]
        _ = try draft.apply(.excludeUnused, existingCategories: [existing])
        XCTAssertFalse(draft.importedData?.categories.contains(where: { $0.id == unused.id }) == true)

        let archived = Account(
            name: "Historical gold",
            type: .physicalAsset,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0),
            isArchived: true
        )
        draft.importedData = FinanceData(accounts: [archived], categories: [], transactions: [])
        draft.createMissingAccounts = false
        XCTAssertNil(draft.creationPolicyError)
        XCTAssertEqual(draft.finalSummary?.archivedAccountCount, 1)

        let active = Account(
            name: "New cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        draft.importedData?.accounts.append(active)
        draft.importedData?.transactions.append(
            LedgerTransaction(
                note: "Active account",
                kind: .expense,
                categoryID: nil,
                outflows: [MoneyMovement(accountID: active.id, money: Money(currency: .usd, minorUnits: 100))],
                inflows: []
            )
        )
        XCTAssertNotNil(draft.creationPolicyError)
    }

    func testImportRuleStoreEncodesDecodesMatchesAndHandlesEmptyLegacyStorage() throws {
        let columns = ["When", "Value", "Wallet"]
        let mapping: [ImportField: String?] = [
            .date: "When",
            .amount: "Value",
            .account: "Wallet",
            .note: nil
        ]
        let rules = ImportRuleStore.remembering(
            mapping: mapping,
            explicitFields: [.date, .account, .note],
            columns: columns,
            accountRules: [
                ImportAccountRule(key: "gold", type: .physicalAsset, currency: .usd, isArchived: true)
            ],
            in: ImportStoredRules()
        )
        let decoded = ImportRuleStore.decoded(try ImportRuleStore.encoded(rules))
        XCTAssertEqual(decoded, rules)

        let applied = ImportRuleStore.applying(
            remembered: decoded,
            to: [:],
            columns: columns
        )
        XCTAssertEqual(applied[.date] ?? nil, "When")
        XCTAssertEqual(applied[.account] ?? nil, "Wallet")
        XCTAssertNil(applied[.amount] ?? nil)
        XCTAssertNil(
            ImportRuleStore.applying(
                remembered: decoded,
                to: [.note: "Notes"],
                columns: columns
            )[.note] ?? nil
        )
        XCTAssertEqual(ImportRuleStore.accountSuggestion(for: "Gold", in: decoded)?.type, .physicalAsset)
        XCTAssertTrue(ImportRuleStore.accountRule(for: "Gold", in: decoded)?.isArchived == true)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ImportRuleStoreTests"))
        defaults.removePersistentDomain(forName: "ImportRuleStoreTests")
        XCTAssertEqual(ImportRuleStore.load(from: defaults), ImportStoredRules())
    }

    func testImportReviewDetectsLikelyDuplicateTransactions() {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let category = LedgerCategory(name: "Food")
        let transaction = LedgerTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            note: "Lunch",
            kind: .expense,
            categoryID: category.id,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 1_250)
                )
            ],
            inflows: []
        )
        let existing = FinanceData(
            accounts: [account],
            categories: [category],
            transactions: [transaction]
        )
        let importedTransaction = LedgerTransaction(
            date: transaction.date,
            note: transaction.note,
            kind: transaction.kind,
            categoryID: category.id,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 1_250)
                )
            ],
            inflows: []
        )
        let imported = FinanceData(
            accounts: [account],
            categories: [category],
            transactions: [importedTransaction]
        )

        XCTAssertEqual(
            FinanceImportReview.duplicateTransactionIDs(in: imported, existing: existing),
            [importedTransaction.id]
        )
    }

    func testImportDefaultsUncategorizedExpensesToOther() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let table = ImportedTable(
            id: "expenses",
            name: "Expenses",
            columns: ["Date", "Type", "Amount", "Currency", "Account", "Category"],
            rows: [["2026-09-06", "Expense", "30", "USD", "Cash", ""]]
        )
        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: account.id,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: FinanceData(accounts: [account], categories: [], transactions: [])
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        let category = try XCTUnwrap(result.data.categories.first)
        XCTAssertEqual(category.name, "Other")
        XCTAssertEqual(transaction.categoryID, category.id)
    }

    func testImportUsesReportingAmountToConvertLocalCurrencyMetrics() throws {
        let account = Account(
            name: "LBP Cash",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        let table = ImportedTable(
            id: "money-manager-expense",
            name: "Money Manager",
            columns: [
                "Date", "Type", "Amount", "Currency", "Reporting amount",
                "Reporting currency", "Account", "Category"
            ],
            rows: [[
                "2026-09-01", "Expense", "200000", "LBP", "2.24", "USD",
                "LBP Cash", "Food"
            ]]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: account.id,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: FinanceData(accounts: [account], categories: [], transactions: [])
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        let rate = try XCTUnwrap(transaction.exchangeRate)
        XCTAssertEqual(transaction.outflows.first?.money, Money(currency: .lbp, minorUnits: 200_000))
        XCTAssertEqual(rate.baseCurrency, .lbp)
        XCTAssertEqual(rate.quoteCurrency, .usd)
        XCTAssertEqual(
            rate.quoteUnitsPerBaseUnit,
            try XCTUnwrap(Decimal(string: "0.0000112"))
        )
        let mergedData = FinanceData(
            accounts: [account] + result.data.accounts,
            categories: result.data.categories,
            transactions: result.data.transactions,
            exchangeRates: result.data.exchangeRates
        )
        XCTAssertEqual(financeNetExpenseAmount(transaction, currency: .lbp, in: mergedData), 200_000)
        XCTAssertEqual(financeNetExpenseAmount(transaction, currency: .usd, in: mergedData), 224)
    }

    func testImportPreservesExplicitPaymentCurrencyWhenAccountUsesAnotherCurrency() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 10_000)
        )
        let table = ImportedTable(
            id: "cross-currency-expense",
            name: "Expenses",
            columns: [
                "Date", "Type", "Amount", "Currency", "Reporting amount",
                "Reporting currency", "Account", "Category"
            ],
            rows: [[
                "2026-09-01", "Expense", "9000000", "LBP", "100", "USD",
                "Cash", "Food"
            ]]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: account.id,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: FinanceData(accounts: [account], categories: [], transactions: [])
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        let movement = try XCTUnwrap(transaction.outflows.first)
        let rate = try XCTUnwrap(transaction.exchangeRate)
        XCTAssertEqual(movement.money, Money(currency: .lbp, minorUnits: 9_000_000))
        XCTAssertEqual(rate.baseCurrency, .lbp)
        XCTAssertEqual(rate.quoteCurrency, .usd)
        XCTAssertEqual(
            financeConvertedMinorUnits(
                movement.money,
                to: account.currency,
                using: rate
            ),
            10_000
        )

        let mergedData = FinanceData(
            accounts: [account],
            categories: result.data.categories,
            transactions: [transaction],
            exchangeRates: result.data.exchangeRates
        )
        XCTAssertNil(FinanceDataValidator.validate(mergedData))
        XCTAssertEqual(LedgerIndex(data: mergedData).balance(for: account).minorUnits, 0)
    }

    func testImportReviewFlagsAmountsOverOneThousandUSD() throws {
        let exactThreshold = LedgerTransaction(
            note: "Exactly one thousand",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: UUID(),
                    money: Money(currency: .usd, minorUnits: FinanceImportReview.suspiciousUSDMinorUnits)
                )
            ],
            inflows: []
        )
        let largeUSD = LedgerTransaction(
            note: "Large USD",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: UUID(),
                    money: Money(currency: .usd, minorUnits: 100_001)
                )
            ],
            inflows: []
        )
        let largeLBP = LedgerTransaction(
            note: "Large LBP",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: UUID(),
                    money: Money(currency: .lbp, minorUnits: 100_000_000)
                )
            ],
            inflows: [],
            exchangeRate: ExchangeRate(
                baseCurrency: .lbp,
                quoteCurrency: .usd,
                quoteUnitsPerBaseUnit: try XCTUnwrap(Decimal(string: "0.0000112"))
            )
        )

        let flagged = FinanceImportReview.suspiciousLargeAmountTransactionIDs(
            in: FinanceData(
                accounts: [],
                categories: [],
                transactions: [exactThreshold, largeUSD, largeLBP]
            )
        )

        XCTAssertFalse(flagged.contains(exactThreshold.id))
        XCTAssertTrue(flagged.contains(largeUSD.id))
        XCTAssertTrue(flagged.contains(largeLBP.id))
    }

    func testImportExcludesModifiedBalanceFromMetrics() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let table = ImportedTable(
            id: "money-manager-balance",
            name: "Money Manager",
            columns: ["Date", "Type", "Amount", "Currency", "Account", "Category"],
            rows: [["2026-09-03", "Expense Balance", "658.83", "USD", "Cash", "Modified Bal."]]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: account.id,
                defaultDestinationAccountID: nil,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: FinanceData(accounts: [account], categories: [], transactions: [])
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        let category = try XCTUnwrap(result.data.categories.first)
        XCTAssertFalse(category.includeInTotals)
        let legacyCategory = LedgerCategory(name: "Modified Bal.")
        XCTAssertFalse(financeCategoryIncludedInTotals(legacyCategory.id, in: [legacyCategory]))
        let mergedData = FinanceData(
            accounts: [account] + result.data.accounts,
            categories: result.data.categories,
            transactions: result.data.transactions,
            exchangeRates: result.data.exchangeRates
        )
        XCTAssertEqual(financeNetExpenseAmount(transaction, currency: .usd, in: mergedData), 0)
    }

    func testImportAddsRateToCrossCurrencyTransfer() throws {
        let source = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let destination = Account(
            name: "Reserve",
            type: .bankAccount,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        let table = ImportedTable(
            id: "transfers",
            name: "Transfers",
            columns: [
                "Date", "Type", "Amount", "Currency", "Account",
                "Destination Account", "Destination Amount", "Destination Currency"
            ],
            rows: [["2026-09-06", "Transfer", "100", "USD", "Cash", "Reserve", "9000000", "LBP"]]
        )
        let existing = FinanceData(accounts: [source, destination], categories: [], transactions: [])
        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: source.id,
                defaultDestinationAccountID: destination.id,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: existing
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        let rate = try XCTUnwrap(transaction.exchangeRate)
        XCTAssertEqual(rate.baseCurrency, .usd)
        XCTAssertEqual(rate.quoteCurrency, .lbp)
        XCTAssertEqual(rate.quoteUnitsPerBaseUnit, 90_000)
        XCTAssertEqual(result.data.exchangeRates, [rate])
        XCTAssertNil(
            FinanceDataValidator.validate(
                FinanceData(
                    accounts: existing.accounts,
                    categories: [],
                    transactions: [transaction],
                    exchangeRates: result.data.exchangeRates
                )
            )
        )
    }

    func testImportConvertsDestinationCurrencyAmountForKnownSourceAccount() throws {
        let source = Account(
            name: "Whish",
            type: .bankAccount,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let destination = Account(
            name: "LBP Cash",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 0)
        )
        let rate = ExchangeRate(
            baseCurrency: .usd,
            quoteCurrency: .lbp,
            quoteUnitsPerBaseUnit: 90_000
        )
        let table = ImportedTable(
            id: "transfers",
            name: "Transfers",
            columns: [
                "Date", "Type", "Amount", "Currency", "Account",
                "Destination Account", "Destination Amount", "Destination Currency"
            ],
            rows: [[
                "2026-09-06", "Transfer", "9000000", "LBP", "Whish",
                "LBP Cash", "9000000", "LBP"
            ]]
        )
        let existing = FinanceData(
            accounts: [source, destination],
            categories: [],
            transactions: [],
            exchangeRates: [rate]
        )

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: source.id,
                defaultDestinationAccountID: destination.id,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: existing
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        XCTAssertEqual(
            transaction.outflows.first?.money,
            Money(currency: .usd, minorUnits: 10_000)
        )
        XCTAssertEqual(
            transaction.inflows.first?.money,
            Money(currency: .lbp, minorUnits: 9_000_000)
        )
        XCTAssertEqual(transaction.exchangeRate, rate)
        XCTAssertNil(
            FinanceDataValidator.validate(
                FinanceData(
                    accounts: existing.accounts,
                    categories: [],
                    transactions: [transaction],
                    exchangeRates: existing.exchangeRates
                )
            )
        )
    }

    func testImportRecastsDestinationMovementToResolvedAccountCurrency() throws {
        let source = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let destination = Account(
            name: "Reserve",
            type: .bankAccount,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let table = ImportedTable(
            id: "transfers",
            name: "Transfers",
            columns: [
                "Date", "Type", "Amount", "Currency", "Account",
                "Destination Account", "Destination Amount", "Destination Currency"
            ],
            rows: [["2026-09-06", "Transfer", "10", "USD", "Cash", "Reserve", "10", "LBP"]]
        )
        let existing = FinanceData(accounts: [source, destination], categories: [], transactions: [])

        let result = try FinanceImportBuilder.build(
            table: table,
            mapping: FinanceImportParser.suggestedMapping(columns: table.columns),
            options: ImportOptions(
                defaultKind: .expense,
                defaultCurrency: .usd,
                defaultAccountID: source.id,
                defaultDestinationAccountID: destination.id,
                createMissingAccounts: true,
                createMissingCategories: true
            ),
            existing: existing
        )

        let transaction = try XCTUnwrap(result.data.transactions.first)
        XCTAssertEqual(
            transaction.inflows.first?.money,
            Money(currency: .usd, minorUnits: 1_000)
        )
        XCTAssertNil(
            FinanceDataValidator.validate(
                FinanceData(
                    accounts: existing.accounts,
                    categories: [],
                    transactions: [transaction],
                    exchangeRates: result.data.exchangeRates
                )
            )
        )
    }

    func testRolloverCarriesUnusedPriorMonthAllowance() {
        let calendar = Calendar(identifier: .gregorian)
        let currentMonth = calendar.dateInterval(of: .month, for: .now)!
        let previousMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth.start)!
        let category = LedgerCategory(name: "Food")
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 10_000)
        )
        let transaction = LedgerTransaction(
            date: calendar.date(byAdding: .day, value: 5, to: previousMonth)!,
            note: "Lunch",
            kind: .expense,
            categoryID: category.id,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .lbp, minorUnits: 300)
                )
            ],
            inflows: []
        )
        let data = FinanceData(
            accounts: [account],
            categories: [category],
            transactions: [transaction]
        )
        let budget = LedgerBudget(
            categoryID: category.id,
            currency: .lbp,
            monthlyLimit: Money(currency: .lbp, minorUnits: 1_000),
            rollover: true,
            startedAt: previousMonth
        )

        XCTAssertEqual(
            financeBudgetSpent(budget, in: data, interval: currentMonth).minorUnits,
            0
        )
        XCTAssertEqual(
            financeBudgetAllowance(budget, in: data, interval: currentMonth).minorUnits,
            1_700
        )
    }

    func testNonRolloverBudgetKeepsMonthlyLimit() {
        let category = LedgerCategory(name: "Food")
        let budget = LedgerBudget(
            categoryID: category.id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 500),
            rollover: false
        )
        let data = FinanceData(
            accounts: [],
            categories: [category],
            transactions: []
        )

        XCTAssertEqual(
            financeBudgetAllowance(budget, in: data).minorUnits,
            500
        )
    }

    func testRolloverCarryIsConsumedByLaterOverspending() {
        let calendar = Calendar(identifier: .gregorian)
        let currentMonth = calendar.dateInterval(of: .month, for: .now)!
        let january = calendar.date(byAdding: .month, value: -2, to: currentMonth.start)!
        let february = calendar.date(byAdding: .month, value: -1, to: currentMonth.start)!
        let category = LedgerCategory(name: "Food")
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 10_000)
        )
        let transactions = [
            LedgerTransaction(
                date: calendar.date(byAdding: .day, value: 5, to: january)!,
                note: "January lunch",
                kind: .expense,
                categoryID: category.id,
                outflows: [
                    MoneyMovement(
                        accountID: account.id,
                        money: Money(currency: .usd, minorUnits: 500)
                    )
                ],
                inflows: []
            ),
            LedgerTransaction(
                date: calendar.date(byAdding: .day, value: 5, to: february)!,
                note: "February lunch",
                kind: .expense,
                categoryID: category.id,
                outflows: [
                    MoneyMovement(
                        accountID: account.id,
                        money: Money(currency: .usd, minorUnits: 1_300)
                    )
                ],
                inflows: []
            )
        ]
        let data = FinanceData(
            accounts: [account],
            categories: [category],
            transactions: transactions
        )
        let budget = LedgerBudget(
            categoryID: category.id,
            currency: .usd,
            monthlyLimit: Money(currency: .usd, minorUnits: 1_000),
            rollover: true,
            startedAt: january
        )

        XCTAssertEqual(financeBudgetAllowance(budget, in: data, interval: currentMonth).minorUnits, 1_200)
    }

    func testMonthlyScheduleAdvancesByOneMonth() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let next = ScheduleFrequency.monthly.nextDate(
            after: date,
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(
            next,
            Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: date)
        )
    }

    func testMonthlySchedulePreservesDayAnchorAcrossShortMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january31 = calendar.date(
            from: DateComponents(year: 2025, month: 1, day: 31, hour: 9)
        )!

        let february = ScheduleFrequency.monthly.nextDate(
            after: january31,
            calendar: calendar,
            monthlyDay: 31
        )!
        XCTAssertEqual(calendar.component(.day, from: february), 28)

        let march = ScheduleFrequency.monthly.nextDate(
            after: february,
            calendar: calendar,
            monthlyDay: 31
        )!
        XCTAssertEqual(calendar.component(.day, from: march), 31)

        let lastDayFebruary = ScheduleFrequency.monthly.nextDate(
            after: january31,
            calendar: calendar,
            monthlyRule: .lastDayOfMonth
        )!
        XCTAssertEqual(calendar.component(.day, from: lastDayFebruary), 28)
    }

    func testLegacyScheduledTransactionDecodesMonthlyDefaults() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let schedule = ScheduledTransaction(
            nextRunDate: Date(timeIntervalSince1970: 1_700_000_000),
            frequency: .monthly,
            note: "Rent",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 1_000)
                )
            ],
            inflows: []
        )
        let encoded = try JSONEncoder().encode(schedule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "monthlyRule")
        object.removeValue(forKey: "recurrenceDay")
        object.removeValue(forKey: "lastSkippedDate")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ScheduledTransaction.self, from: legacyData)
        XCTAssertEqual(decoded.monthlyRule, .dayOfMonth)
        XCTAssertEqual(
            decoded.recurrenceDay,
            Calendar.current.component(.day, from: schedule.nextRunDate)
        )
        XCTAssertNil(decoded.reminderTiming)
        XCTAssertNil(decoded.lastSkippedDate)
    }

    func testTemplateCreatesFreshTransactionAndMovementIDs() {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let transaction = LedgerTransaction(
            note: "Coffee",
            kind: .expense,
            categoryID: nil,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 500)
                )
            ],
            inflows: []
        )
        let template = LedgerTemplate(name: "Coffee", transaction: transaction)
        let copy = template.transactionTemplate

        XCTAssertNotEqual(copy.id, transaction.id)
        XCTAssertNotEqual(copy.outflows.first?.id, transaction.outflows.first?.id)
        XCTAssertEqual(copy.outflows.first?.accountID, account.id)
        XCTAssertEqual(copy.outflows.first?.money, transaction.outflows.first?.money)
    }

    func testTransactionDefaultsUseRememberedAccountAndPreserveUncategorizedEdits() throws {
        let firstAccount = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let rememberedAccount = Account(
            name: "Travel card",
            type: .bankAccount,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let rememberedCategory = LedgerCategory(name: "Food")
        let account = try XCTUnwrap(FinanceTransactionDefaults.primaryAccount(
            in: [firstAccount, rememberedAccount],
            sourceAccountID: nil,
            scheduledAccountID: nil,
            rememberedAccountID: rememberedAccount.id,
            preferredCurrency: .usd
        ))

        XCTAssertEqual(account.id, rememberedAccount.id)
        let uncategorized = LedgerTransaction(
            note: "Uncategorized purchase",
            kind: .expense,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: firstAccount.id, money: Money(currency: .usd, minorUnits: 250))],
            inflows: []
        )
        XCTAssertNil(FinanceTransactionDefaults.categoryID(
            sourceTransaction: uncategorized,
            scheduledTransaction: nil,
            rememberedCategoryID: rememberedCategory.id,
            activeCategories: [rememberedCategory]
        ))
        XCTAssertEqual(FinanceTransactionDefaults.categoryID(
            sourceTransaction: nil,
            scheduledTransaction: nil,
            rememberedCategoryID: rememberedCategory.id,
            activeCategories: [rememberedCategory]
        ), rememberedCategory.id)
    }

    func testTransactionListTotalsFollowFilterAndKeepValidPage() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let expense = LedgerTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_001),
            note: "Lunch",
            kind: .expense,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 1_500))],
            inflows: []
        )
        let income = LedgerTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_002),
            note: "Pay",
            kind: .income,
            categoryID: nil,
            outflows: [],
            inflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 2_500))],
            exchangeRate: ExchangeRate(
                baseCurrency: .usd,
                quoteCurrency: .lbp,
                quoteUnitsPerBaseUnit: Decimal(90_000)
            )
        )
        let transfer = LedgerTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_003),
            note: "Move money",
            kind: .transfer,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 500))],
            inflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 500))]
        )
        let data = FinanceData(accounts: [account], categories: [], transactions: [expense, income, transfer])
        let index = LedgerIndex(data: data)
        let incomeSnapshot = TransactionListSnapshot.make(
            index: index,
            filter: .income,
            period: .all,
            quickFilter: .none,
            searchText: "",
            customStartDate: .distantPast,
            customEndDate: .distantFuture,
            page: 0,
            pageSize: 10
        )
        XCTAssertEqual(incomeSnapshot.incomeTotals[.usd], 2_500)
        XCTAssertEqual(
            incomeSnapshot.incomeTotals[.lbp],
            financeConvertedMinorUnits(
                income.inflows[0].money,
                to: .lbp,
                using: income.exchangeRate
            )
        )
        XCTAssertEqual(incomeSnapshot.expenseTotals[.usd], nil)

        let allSnapshot = TransactionListSnapshot.make(
            index: index,
            filter: .all,
            period: .all,
            quickFilter: .none,
            searchText: "",
            customStartDate: .distantPast,
            customEndDate: .distantFuture,
            page: 1,
            pageSize: 1
        )
        XCTAssertEqual(allSnapshot.expenseTotals[.usd], 1_500)
        XCTAssertEqual(allSnapshot.incomeTotals[.usd], 2_500)
        XCTAssertEqual(allSnapshot.displayedPage, 1)
        XCTAssertEqual(allSnapshot.pageTransactions.count, 1)

        let afterDelete = LedgerIndex(data: FinanceData(
            accounts: [account],
            categories: [],
            transactions: [expense, transfer]
        ))
        let retainedPage = TransactionListSnapshot.make(
            index: afterDelete,
            filter: .all,
            period: .all,
            quickFilter: .none,
            searchText: "",
            customStartDate: .distantPast,
            customEndDate: .distantFuture,
            page: 1,
            pageSize: 1
        )
        XCTAssertEqual(retainedPage.displayedPage, 1)
        XCTAssertEqual(retainedPage.pageTransactions.count, 1)
    }

    func testScheduleRecordUndoRestoresOnlyUnchangedRecords() throws {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let previousSchedule = ScheduledTransaction(
            nextRunDate: Date(timeIntervalSince1970: 1_700_000_000),
            frequency: .once,
            note: "Rent",
            kind: .expense,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: account.id, money: Money(currency: .usd, minorUnits: 50_000))],
            inflows: []
        )
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        var recordedSchedule = previousSchedule
        recordedSchedule.isEnabled = false
        recordedSchedule.lastRunDate = now
        let transaction = previousSchedule.materializedTransaction(on: now)
        let receipt = ScheduleRecordUndoReceipt(
            transaction: transaction,
            previousSchedule: previousSchedule,
            recordedSchedule: recordedSchedule
        )
        let data = FinanceData(
            accounts: [account],
            categories: [],
            transactions: [transaction],
            scheduledTransactions: [recordedSchedule]
        )

        let restored = try XCTUnwrap(financeUndoScheduleRecord(receipt, in: data))
        XCTAssertTrue(restored.transactions.isEmpty)
        XCTAssertEqual(restored.scheduledTransactions, [previousSchedule])

        var changedSince = data
        changedSince.scheduledTransactions[0].note = "Updated rent"
        XCTAssertNil(financeUndoScheduleRecord(receipt, in: changedSince))

        changedSince = data
        changedSince.transactions[0].note = "Updated recorded rent"
        XCTAssertNil(financeUndoScheduleRecord(receipt, in: changedSince))
    }

    func testImportPreparationRejectsStaleInputsAndDropsStagedResults() {
        let table = ImportedTable(id: "transactions", name: "Transactions", columns: [], rows: [])
        let document = ImportedDocument(fileName: "ledger.csv", format: .delimited, tables: [table])
        var draft = ImportDraft(document: document, existing: .empty, rememberedRules: ImportStoredRules())
        let inputs = ImportPreparationInputs(draft: draft, ledgerRevision: 4)
        XCTAssertTrue(inputs.matches(draft, ledgerRevision: 4))
        var changedDraft = draft
        changedDraft.defaultKind = .income
        XCTAssertFalse(inputs.matches(changedDraft, ledgerRevision: 4))
        XCTAssertFalse(inputs.matches(draft, ledgerRevision: 5))

        draft.step = .organize
        draft.result = FinanceImportResult(data: .empty, importedRows: 1, skippedRows: 0, warnings: [])
        draft.importedData = .empty
        draft.duplicateTransactionIDs = [UUID()]

        draft.discardPreparedResults()

        XCTAssertNil(draft.result)
        XCTAssertNil(draft.importedData)
        XCTAssertTrue(draft.duplicateTransactionIDs.isEmpty)
    }

    func testWatchCacheReadsOlderQueuedItemsAndDoesNotResendRejectedOnes() throws {
        let rejected = WatchExpenseCommand(
            amount: Money(currency: .usd, minorUnits: 900),
            accountID: UUID(),
            categoryID: nil,
            note: "Coffee"
        )
        let queued = WatchExpenseCommand(
            amount: Money(currency: .usd, minorUnits: 1_200),
            accountID: UUID(),
            categoryID: nil,
            note: "Lunch"
        )
        let currentData = try JSONEncoder().encode(WatchLedgerCache(
            snapshot: nil,
            pendingExpenses: [rejected, queued],
            lastSyncDate: nil,
            lastError: nil,
            failedExpenseMessages: [rejected.id: "The account is unavailable."]
        ))
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        legacyObject.removeValue(forKey: "failedExpenseMessages")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder().decode(WatchLedgerCache.self, from: legacyData)

        XCTAssertEqual(decodedLegacy.pendingExpenses, [rejected, queued])
        XCTAssertTrue(decodedLegacy.failedExpenseMessages.isEmpty)
        XCTAssertEqual(
            WatchExpenseQueuePolicy.commandsReadyToSend(
                [rejected, queued, queued],
                rejectedIDs: [rejected.id]
            ),
            [queued]
        )
        let failures = [rejected.id: "The account is unavailable."]
        let retried = try XCTUnwrap(WatchExpenseQueuePolicy.retryFailedExpense(
            id: rejected.id,
            commands: [rejected, queued],
            failures: failures
        ))
        XCTAssertEqual(retried.commands, [rejected, queued])
        XCTAssertTrue(retried.failures.isEmpty)

        let corrected = try XCTUnwrap(WatchExpenseQueuePolicy.correctAndRetryFailedExpense(
            id: rejected.id,
            amount: Money(currency: .usd, minorUnits: 1_000),
            accountID: queued.accountID,
            categoryID: nil,
            note: "Coffee corrected",
            commands: [rejected, queued],
            failures: failures
        ))
        XCTAssertEqual(corrected.commands[0].id, rejected.id)
        XCTAssertEqual(corrected.commands[0].date, rejected.date)
        XCTAssertEqual(corrected.commands[0].amount.minorUnits, 1_000)
        XCTAssertTrue(corrected.failures.isEmpty)

        let discarded = try XCTUnwrap(WatchExpenseQueuePolicy.discardFailedExpense(
            id: rejected.id,
            commands: [rejected, queued, rejected],
            failures: failures
        ))
        XCTAssertEqual(discarded.commands, [queued])
        XCTAssertTrue(discarded.failures.isEmpty)
        XCTAssertNil(WatchExpenseQueuePolicy.discardFailedExpense(
            id: rejected.id,
            commands: [queued],
            failures: [:]
        ))

        let alreadyRecorded = LedgerTransaction(
            id: rejected.id,
            date: rejected.date,
            note: rejected.note,
            kind: .expense,
            categoryID: rejected.categoryID,
            outflows: [MoneyMovement(accountID: rejected.accountID, money: rejected.amount)],
            inflows: []
        )
        XCTAssertTrue(WatchExpenseQueuePolicy.wasAlreadyRecorded(
            commandID: rejected.id,
            in: [alreadyRecorded]
        ))
        XCTAssertFalse(WatchExpenseQueuePolicy.wasAlreadyRecorded(
            commandID: rejected.id,
            in: []
        ))
    }

    func testWatchSnapshotWorkRequiresEligibleDelivery() {
        XCTAssertFalse(WatchSyncPublisher.isEligibleForDelivery(
            sessionSupported: false,
            isActivated: true,
            isWatchAppInstalled: true
        ))
        XCTAssertFalse(WatchSyncPublisher.isEligibleForDelivery(
            sessionSupported: true,
            isActivated: true,
            isWatchAppInstalled: false
        ))
        XCTAssertFalse(WatchSyncPublisher.isEligibleForDelivery(
            sessionSupported: true,
            isActivated: false,
            isWatchAppInstalled: true
        ))
        XCTAssertTrue(WatchSyncPublisher.isEligibleForDelivery(
            sessionSupported: true,
            isActivated: true,
            isWatchAppInstalled: true
        ))
    }

    func testWatchExpenseCommandRoundTripsThroughConnectivityCodec() throws {
        let command = WatchExpenseCommand(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            amount: Money(currency: .usd, minorUnits: 1_250),
            accountID: UUID(),
            categoryID: UUID(),
            note: "Coffee"
        )

        let context = try XCTUnwrap(WatchSyncCodec.dictionary(for: command))
        let decoded = try XCTUnwrap(WatchSyncCodec.expenseCommand(from: context))

        XCTAssertEqual(decoded, command)
    }

    func testWatchSnapshotIncludesBalancesAndRecentActivity() {
        let account = Account(
            name: "Cash",
            type: .cash,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 10_000)
        )
        let category = LedgerCategory(name: "Food")
        let transaction = LedgerTransaction(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            note: "Lunch",
            kind: .expense,
            categoryID: category.id,
            outflows: [
                MoneyMovement(
                    accountID: account.id,
                    money: Money(currency: .usd, minorUnits: 1_250)
                )
            ],
            inflows: []
        )

        let snapshot = WatchSyncPublisher.makeSnapshot(
            from: FinanceData(
                accounts: [account],
                categories: [category],
                transactions: [transaction]
            ),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertEqual(snapshot.balances.first { $0.currency == .usd }?.balance.minorUnits, 8_750)
        XCTAssertEqual(snapshot.accounts.first?.name, "Cash")
        XCTAssertEqual(snapshot.recentTransactions.first?.categoryPath, "Food")
        XCTAssertEqual(snapshot.recentTransactions.first?.amount.minorUnits, 1_250)
    }

    func testLegacyWatchSnapshotDefaultsPlanningFields() throws {
        let snapshot = WatchLedgerSnapshot(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            balances: [],
            accounts: [],
            categories: [],
            recentTransactions: []
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attentionCount")
        object.removeValue(forKey: "upcomingScheduledCount")

        let decoded = try JSONDecoder().decode(
            WatchLedgerSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.attentionCount, 0)
        XCTAssertEqual(decoded.upcomingScheduledCount, 0)
    }
}
