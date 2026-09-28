import Foundation
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

struct PocketLedgerBackup: Codable {
    static let format = "pocket-ledger-backup"
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let data: FinanceData

    init(data: FinanceData, exportedAt: Date = .now) {
        format = Self.format
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.data = data
    }
}

struct PocketLedgerBackupAttachment: Codable {
    let id: UUID
    let data: Data
}

struct PocketLedgerBackupBundle: Codable {
    static let format = "pocket-ledger-backup-bundle"
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let data: FinanceData
    let attachments: [PocketLedgerBackupAttachment]

    init(data: FinanceData, attachmentData: [UUID: Data], exportedAt: Date = .now) {
        format = Self.format
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.data = data
        attachments = data.attachments.compactMap { attachment in
            attachmentData[attachment.id].map {
                PocketLedgerBackupAttachment(id: attachment.id, data: $0)
            }
        }
    }
}

enum LedgerBackupCodec {
    static func encode(_ data: FinanceData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(PocketLedgerBackup(data: data))
    }

    static func decode(_ data: Data) throws -> PocketLedgerBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(PocketLedgerBackup.self, from: data)
        guard backup.format == PocketLedgerBackup.format,
              backup.version <= PocketLedgerBackup.currentVersion else {
            throw FinanceImportError.invalidFile("This Pocket Ledger backup version is not supported.")
        }
        return backup
    }

    static func encodeBundle(_ data: FinanceData, attachmentData: [UUID: Data]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            PocketLedgerBackupBundle(data: data, attachmentData: attachmentData)
        )
    }

    static func decodeBundle(_ data: Data) throws -> PocketLedgerBackupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(PocketLedgerBackupBundle.self, from: data)
        guard backup.format == PocketLedgerBackupBundle.format,
              backup.version <= PocketLedgerBackupBundle.currentVersion else {
            throw FinanceImportError.invalidFile("This Pocket Ledger backup bundle version is not supported.")
        }
        return backup
    }
}

struct PocketLedgerBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PocketLedgerBackupBundleDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LedgerCSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ImportedFileFormat: String {
    case delimited
    case sqlite
    case json
    case spreadsheet

    var displayName: String {
        switch self {
        case .delimited:
            return "CSV / TSV"
        case .sqlite:
            return "SQLite backup"
        case .json:
            return "JSON"
        case .spreadsheet:
            return "Excel workbook"
        }
    }
}

struct ImportedTable: Identifiable {
    let id: String
    let name: String
    let columns: [String]
    let rows: [[String]]
}

struct ImportedDocument: Identifiable {
    let id = UUID()
    let fileName: String
    let format: ImportedFileFormat
    let tables: [ImportedTable]

    var preferredTable: ImportedTable? {
        tables.first
    }
}

enum ImportField: String, CaseIterable, Identifiable, Hashable {
    case date
    case kind
    case amount
    case currency
    case baseAmount
    case baseCurrency
    case accountType
    case account
    case destinationAccountType
    case destinationAccount
    case destinationAmount
    case destinationCurrency
    case category
    case note

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .date:
            return "Date"
        case .kind:
            return "Type"
        case .amount:
            return "Amount"
        case .currency:
            return "Currency"
        case .baseAmount:
            return "Reporting amount"
        case .baseCurrency:
            return "Reporting currency"
        case .account:
            return "Account"
        case .accountType:
            return "Account type"
        case .destinationAccount:
            return "Destination account"
        case .destinationAccountType:
            return "Destination account type"
        case .destinationAmount:
            return "Destination amount"
        case .destinationCurrency:
            return "Destination currency"
        case .category:
            return "Category"
        case .note:
            return "Note / description"
        }
    }

    var helpText: String {
        switch self {
        case .date:
            return "When the transaction happened"
        case .kind:
            return "Expense, income, or transfer"
        case .amount:
            return "The transaction amount"
        case .currency:
            return "USD, LBP, EUR, or another currency label"
        case .baseAmount:
            return "Equivalent amount in the reporting currency"
        case .baseCurrency:
            return "Currency used for the reporting amount"
        case .account:
            return "The account money leaves or enters"
        case .accountType:
            return "Cash, bank account, loan, asset, or investment"
        case .destinationAccount:
            return "The receiving account for transfers"
        case .destinationAccountType:
            return "The receiving account type for transfers"
        case .destinationAmount:
            return "Amount received by the destination account"
        case .destinationCurrency:
            return "Currency received by the destination account"
        case .category:
            return "Category or subcategory name"
        case .note:
            return "Memo, payee, or description"
        }
    }
}

struct ImportOptions {
    let defaultKind: TransactionKind
    let defaultCurrency: LedgerCurrency
    let defaultAccountID: UUID?
    let defaultDestinationAccountID: UUID?
    let createMissingAccounts: Bool
    let createMissingCategories: Bool
    let accountSuggestions: [String: ImportAccountSuggestion]

    init(
        defaultKind: TransactionKind,
        defaultCurrency: LedgerCurrency,
        defaultAccountID: UUID?,
        defaultDestinationAccountID: UUID?,
        createMissingAccounts: Bool,
        createMissingCategories: Bool,
        accountSuggestions: [String: ImportAccountSuggestion] = [:]
    ) {
        self.defaultKind = defaultKind
        self.defaultCurrency = defaultCurrency
        self.defaultAccountID = defaultAccountID
        self.defaultDestinationAccountID = defaultDestinationAccountID
        self.createMissingAccounts = createMissingAccounts
        self.createMissingCategories = createMissingCategories
        self.accountSuggestions = accountSuggestions
    }
}

struct ImportAccountCandidate: Equatable, Sendable {
    let name: String
    let observedCurrencies: [String]
    let observedTypes: [String]

    static func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ImportAccountSuggestion: Equatable, Sendable {
    let type: AccountType?
    let currency: LedgerCurrency?
}

struct FinanceImportResult {
    let data: FinanceData
    let importedRows: Int
    let skippedRows: Int
    let warnings: [String]
}

enum FinanceImportReview {
    static let suspiciousUSDMinorUnits: Int64 = 100_000

    static func suspiciousLargeAmountTransactionIDs(
        in imported: FinanceData,
        thresholdUSDMinorUnits: Int64 = FinanceImportReview.suspiciousUSDMinorUnits
    ) -> Set<UUID> {
        Set(
            imported.transactions.compactMap { transaction in
                let hasLargeMovement = (transaction.outflows + transaction.inflows).contains { movement in
                    guard let usdMinorUnits = financeConvertedMinorUnits(
                        movement.money,
                        to: .usd,
                        using: transaction.exchangeRate
                    ) else {
                        return false
                    }
                    return usdMinorUnits > thresholdUSDMinorUnits
                }
                return hasLargeMovement ? transaction.id : nil
            }
        )
    }

    static func duplicateTransactionIDs(
        in imported: FinanceData,
        existing: FinanceData
    ) -> Set<UUID> {
        var existingFingerprints: Set<String> = []
        for transaction in existing.transactions {
            if Task.isCancelled { return [] }
            existingFingerprints.insert(transactionFingerprint(transaction, in: existing))
        }

        var duplicates: Set<UUID> = []
        for transaction in imported.transactions {
            if Task.isCancelled { return [] }
            if existingFingerprints.contains(transactionFingerprint(transaction, in: imported)) {
                duplicates.insert(transaction.id)
            }
        }
        return duplicates
    }

    static func removingUnusedCreatedRecords(from data: FinanceData) -> FinanceData {
        var prepared = data
        let referencedAccountIDs = Set(
            prepared.transactions.flatMap { transaction in
                transaction.outflows.map(\.accountID) + transaction.inflows.map(\.accountID)
            }
        )
        prepared.accounts.removeAll {
            !referencedAccountIDs.contains($0.id) && !$0.isArchived
        }

        var referencedCategoryIDs = Set(
            prepared.transactions.compactMap(\.categoryID)
        )
        while let category = prepared.categories.first(where: {
            guard referencedCategoryIDs.contains($0.id), let parentID = $0.parentID else { return false }
            return !referencedCategoryIDs.contains(parentID)
        }), let parentID = category.parentID {
            referencedCategoryIDs.insert(parentID)
        }
        prepared.categories.removeAll { !referencedCategoryIDs.contains($0.id) }

        return prepared
    }

    private static func transactionFingerprint(
        _ transaction: LedgerTransaction,
        in data: FinanceData
    ) -> String {
        let day = Calendar.current.startOfDay(for: transaction.date).timeIntervalSince1970
        let category = categoryPath(for: transaction.categoryID, in: data)
        let outflows = movementFingerprints(transaction.outflows, in: data).joined(separator: ";")
        let inflows = movementFingerprints(transaction.inflows, in: data).joined(separator: ";")
        let amountDue = transaction.amountDue.map { "\($0.currency.rawValue):\($0.minorUnits)" } ?? "-"
        return [
            String(Int64(day)),
            transaction.kind.rawValue,
            transaction.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            category,
            outflows,
            inflows,
            amountDue
        ].joined(separator: "|")
    }

    private static func movementFingerprints(
        _ movements: [MoneyMovement],
        in data: FinanceData
    ) -> [String] {
        movements.map { movement in
            let account = data.accounts.first(where: { $0.id == movement.accountID })
            return [
                account?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "?",
                movement.money.currency.rawValue,
                String(movement.money.minorUnits)
            ].joined(separator: ":")
        }.sorted()
    }

    private static func categoryPath(
        for categoryID: UUID?,
        in data: FinanceData
    ) -> String {
        var names: [String] = []
        var currentID = categoryID
        var visited: Set<UUID> = []
        while let id = currentID,
              visited.insert(id).inserted,
              let category = data.categories.first(where: { $0.id == id }) {
            names.append(category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            currentID = category.parentID
        }
        return names.reversed().joined(separator: "/")
    }
}

enum FinanceImportError: LocalizedError {
    case invalidFile(String)
    case missingMapping(ImportField)
    case noImportableRows
    case row(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let message):
            return message
        case .missingMapping(let field):
            return "Map the \(field.displayName) column before importing."
        case .noImportableRows:
            return "No rows could be imported. Check the field mapping and defaults."
        case .row(let message):
            return message
        }
    }
}

enum FinanceImportParser {
    private static let sqliteHeader = Data("SQLite format 3".utf8)

    static func parse(url: URL, data: Data) throws -> ImportedDocument {
        let fileExtension = url.pathExtension.lowercased()

        if data.starts(with: sqliteHeader) || ["mmbak", "sqlite", "sqlite3", "db"].contains(fileExtension) {
            guard data.starts(with: sqliteHeader) else {
                throw FinanceImportError.invalidFile("This file is named as SQLite, but it does not contain a readable SQLite database.")
            }
            return try parseSQLite(url: url)
        }

        if fileExtension == "json" {
            return try parseJSON(data: data, fileName: url.lastPathComponent)
        }

        if data.starts(with: Data("PK".utf8)) {
            if ["xlsx", "xlsm"].contains(fileExtension) {
                return try parseXLSX(url: url)
            }
            throw FinanceImportError.invalidFile("This is a ZIP archive. Choose an Excel workbook, a Pocket Ledger backup, or a CSV/TSV export.")
        }

        if ["xlsx", "xlsm"].contains(fileExtension) {
            throw FinanceImportError.invalidFile("The Excel workbook is not a readable .xlsx file.")
        }

        if data.starts(with: Data([0xD0, 0xCF, 0x11, 0xE0])) {
            throw FinanceImportError.invalidFile("Legacy binary .xls workbooks are not supported. Export the sheet as .xlsx, CSV, or TSV and try again.")
        }

        return try parseDelimited(data: data, fileName: url.lastPathComponent)
    }

    static func suggestedMapping(columns: [String]) -> [ImportField: String?] {
        let aliases: [ImportField: [String]] = [
            .date: ["date", "day", "period", "txdate", "txdatestr", "transactiondate", "createdat", "timestamp"],
            .kind: ["type", "kind", "transactiontype", "recordtype", "incomeexpense", "dotype"],
            .amount: ["amount", "money", "value", "total", "price", "sum", "zamoun"],
            .currency: ["currency", "currencycode", "currencyname", "iso", "symbol"],
            .baseAmount: ["baseamount", "reportingamount", "usdequivalent", "usdamount", "amountusd", "usd"],
            .baseCurrency: ["basecurrency", "reportingcurrency", "usdcurrency"],
            .account: ["account", "asset", "assets", "fromaccount", "sourceaccount", "assetname", "zasset"],
            .accountType: ["accounttype", "assettype", "fromaccounttype", "sourceaccounttype"],
            .destinationAccount: ["toaccount", "destination", "destinationaccount", "transferaccount", "toasset"],
            .destinationAccountType: ["destinationaccounttype", "toaccounttype", "toassettype"],
            .destinationAmount: ["destinationamount", "toamount", "receivedamount", "inflowamount", "targetamount"],
            .destinationCurrency: ["destinationcurrency", "tocurrency", "receivedcurrency", "inflowcurrency", "targetcurrency"],
            .category: ["category", "subcategory", "categoryname", "categorypath", "zcategory"],
            .note: ["note", "memo", "description", "details", "content", "contents", "payee", "comment"]
        ]

        var used: Set<String> = []
        var assigned: Set<ImportField> = []
        var result: [ImportField: String?] = [:]

        for field in ImportField.allCases {
            let candidate = columns.first { column in
                guard !used.contains(column) else { return false }
                let normalizedColumn = normalize(column)
                return aliases[field, default: []].contains { alias in
                    normalizedColumn == normalize(alias)
                }
            }
            result[field] = candidate
            if let candidate {
                used.insert(candidate)
                assigned.insert(field)
            }
        }

        for field in ImportField.allCases where !assigned.contains(field) {
            let candidate = columns.first { column in
                guard !used.contains(column) else { return false }
                let normalizedColumn = normalize(column)
                return aliases[field, default: []].contains { alias in
                    normalizedColumn.contains(normalize(alias))
                }
            }
            result[field] = candidate
            if let candidate {
                used.insert(candidate)
            }
        }

        return result
    }

    private static func parseDelimited(data: Data, fileName: String) throws -> ImportedDocument {
        guard let text = decodeText(data)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw FinanceImportError.invalidFile("The selected file is empty or is not readable text.")
        }

        let delimiter = detectDelimiter(in: text)
        let rawRows = parseDelimitedRows(text, delimiter: delimiter)
        guard let headerRow = rawRows.first, !headerRow.isEmpty else {
            throw FinanceImportError.invalidFile("No column headers were found in this file.")
        }

        let columns = uniqueHeaders(headerRow)
        let rows = rawRows.dropFirst().filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }.map { row in
            row + Array(repeating: "", count: max(0, columns.count - row.count))
        }.map { Array($0.prefix(columns.count)) }

        guard !rows.isEmpty else {
            throw FinanceImportError.invalidFile("The file has headers but no data rows.")
        }

        return ImportedDocument(
            fileName: fileName,
            format: .delimited,
            tables: [ImportedTable(id: "sheet-1", name: "Imported rows", columns: columns, rows: rows)]
        )
    }

    private static func parseJSON(data: Data, fileName: String) throws -> ImportedDocument {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FinanceImportError.invalidFile("The JSON file could not be read.")
        }

        guard let dictionaries = object as? [[String: Any]], !dictionaries.isEmpty else {
            throw FinanceImportError.invalidFile("JSON imports must contain an array of row objects.")
        }

        var columns: [String] = []
        for dictionary in dictionaries {
            for key in dictionary.keys where !columns.contains(key) {
                columns.append(key)
            }
        }

        let rows = dictionaries.map { dictionary in
            columns.map { key in
                stringifyJSONValue(dictionary[key])
            }
        }

        return ImportedDocument(
            fileName: fileName,
            format: .json,
            tables: [ImportedTable(id: "json-rows", name: "JSON rows", columns: columns, rows: rows)]
        )
    }

    private static func parseXLSX(url: URL) throws -> ImportedDocument {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw FinanceImportError.invalidFile("The Excel workbook could not be opened.")
        }

        let sharedStrings: [String]
        if let sharedStringData = try? archiveData(at: "xl/sharedStrings.xml", in: archive) {
            sharedStrings = try parseSharedStrings(sharedStringData)
        } else {
            sharedStrings = []
        }

        let workbookData = try archiveData(at: "xl/workbook.xml", in: archive)
        let relationshipsData = try archiveData(at: "xl/_rels/workbook.xml.rels", in: archive)
        let sheets = try parseWorkbook(workbookData)
        let relationships = try parseRelationships(relationshipsData)
        var rawTables: [ImportedTable] = []
        var normalizedTables: [ImportedTable] = []

        for (index, sheet) in sheets.enumerated() {
            guard let target = relationships[sheet.relationshipID] else { continue }
            let worksheetPath = worksheetArchivePath(for: target)
            guard let worksheetData = try? archiveData(at: worksheetPath, in: archive) else { continue }
            let parsedSheet = try parseWorksheet(worksheetData, sharedStrings: sharedStrings)
            guard let headerRow = parsedSheet.first, !headerRow.isEmpty else { continue }

            let columns = uniqueHeaders(headerRow)
            let rows = parsedSheet.dropFirst().filter { row in
                row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }.map { row in
                row + Array(repeating: "", count: max(0, columns.count - row.count))
            }.map { Array($0.prefix(columns.count)) }

            guard !rows.isEmpty else { continue }
            let table = ImportedTable(
                id: "xlsx-\(index + 1)",
                name: sheet.name,
                columns: columns,
                rows: rows
            )
            rawTables.append(table)
            if let normalized = makeMoneyManagerSpreadsheetNormalizedTable(from: table) {
                normalizedTables.append(normalized)
            }
        }

        let tables = normalizedTables + rawTables
        guard !tables.isEmpty else {
            throw FinanceImportError.invalidFile("The Excel workbook does not contain any readable rows.")
        }

        return ImportedDocument(
            fileName: url.lastPathComponent,
            format: .spreadsheet,
            tables: tables
        )
    }

    private static func archiveData(at path: String, in archive: Archive) throws -> Data {
        guard let entry = archive[path] else {
            throw FinanceImportError.invalidFile("The Excel workbook is missing \(path).")
        }

        var data = Data()
        try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
        })
        return data
    }

    private static func parseWorkbook(_ data: Data) throws -> [XLSXSheetReference] {
        let delegate = XLSXWorkbookDelegate()
        try parseXML(data, delegate: delegate)
        return delegate.sheets
    }

    private static func parseRelationships(_ data: Data) throws -> [String: String] {
        let delegate = XLSXRelationshipsDelegate()
        try parseXML(data, delegate: delegate)
        return delegate.targets
    }

    private static func parseSharedStrings(_ data: Data) throws -> [String] {
        let delegate = XLSXSharedStringsDelegate()
        try parseXML(data, delegate: delegate)
        return delegate.values
    }

    private static func parseWorksheet(_ data: Data, sharedStrings: [String]) throws -> [[String]] {
        let delegate = XLSXWorksheetDelegate(sharedStrings: sharedStrings)
        try parseXML(data, delegate: delegate)
        let columnCount = delegate.rows.flatMap(\.keys).max().map { $0 + 1 } ?? 0
        return delegate.rows.map { row in
            (0..<columnCount).map { row[$0] ?? "" }
        }
    }

    private static func parseXML(_ data: Data, delegate: NSObject & XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw FinanceImportError.invalidFile(parser.parserError?.localizedDescription ?? "The XML data could not be read.")
        }
    }

    private static func worksheetArchivePath(for target: String) -> String {
        let normalized = target.hasPrefix("/") ? String(target.dropFirst()) : target
        if normalized.hasPrefix("xl/") {
            return normalized
        }
        return "xl/\(normalized)"
    }

    private static func makeMoneyManagerSpreadsheetNormalizedTable(from table: ImportedTable) -> ImportedTable? {
        let dateIndex = columnIndex(in: table, aliases: ["PERIOD", "DATE", "TXDATE", "TRANSACTIONDATE"])
        let accountIndex = columnIndex(in: table, aliases: ["ACCOUNTS", "ACCOUNT", "ASSET"])
        let categoryIndex = columnIndex(in: table, aliases: ["CATEGORY"])
        let subcategoryIndex = columnIndex(in: table, aliases: ["SUBCATEGORY"])
        let noteIndex = columnIndex(in: table, aliases: ["NOTE", "MEMO"])
        let descriptionIndex = columnIndex(in: table, aliases: ["DESCRIPTION", "DETAILS"])
        let typeIndex = columnIndex(in: table, aliases: ["INCOMEEXPENSE", "TYPE", "KIND"])
        let amountIndex = columnIndex(in: table, aliases: ["AMOUNT", "VALUE", "MONEY"])
        let currencyIndex = columnIndex(in: table, aliases: ["CURRENCY", "CURRENCYCODE"])
        let usdIndex = columnIndex(in: table, aliases: ["USD", "USDEQUIVALENT", "BASEAMOUNT"])
        // Money Manager exports a second "Accounts" column with amounts in each account's currency.
        let accountCurrencyAmountIndex = table.columns.firstIndex {
            normalize($0) == "accounts2"
        }

        guard let dateIndex, let accountIndex, let typeIndex, let amountIndex, let currencyIndex else {
            return nil
        }

        func accountCurrencyAmount(in row: [String]?, currency: LedgerCurrency?) -> String? {
            guard let row, let currency else { return nil }
            let rawAmount = cell(row, accountCurrencyAmountIndex ?? -1)
            guard let amount = Money.parse(
                rawAmount,
                currency: currency,
                locale: Locale(identifier: "en_US_POSIX")
            ), amount.minorUnits > 0 else {
                return nil
            }
            return rawAmount
        }

        let normalizedColumns = [
            "Date",
            "Type",
            "Amount",
            "Currency",
            "Reporting amount",
            "Reporting currency",
            "Account",
            "Destination Account",
            "Destination Amount",
            "Destination Currency",
            "Category",
            "Note"
        ]
        let transferRows = table.rows.enumerated().filter { row in
            spreadsheetKind(cell(row.element, typeIndex)) == .transfer
        }
        var consumedTransferRows: Set<Int> = []
        var rows: [[String]] = []

        for (rowIndex, row) in table.rows.enumerated() {
            guard let kind = spreadsheetKind(cell(row, typeIndex)) else { continue }
            if kind == .transfer {
                guard !consumedTransferRows.contains(rowIndex) else { continue }

                let date = cell(row, dateIndex)
                let amount = cell(row, amountIndex)
                let currency = cell(row, currencyIndex)
                let matchingRows = transferRows.filter { candidate in
                    !consumedTransferRows.contains(candidate.offset)
                        && candidate.offset != rowIndex
                        && cell(candidate.element, dateIndex) == date
                        && cell(candidate.element, amountIndex) == amount
                        && cell(candidate.element, currencyIndex) == currency
                }
                let counterpart = matchingRows.first
                let canonicalIndex: Int
                if normalizedSpreadsheetKind(cell(row, typeIndex)) == "transferout" {
                    canonicalIndex = rowIndex
                } else if let counterpart,
                          normalizedSpreadsheetKind(cell(counterpart.element, typeIndex)) == "transferout" {
                    canonicalIndex = counterpart.offset
                } else {
                    canonicalIndex = rowIndex
                }

                let canonicalRow = table.rows[canonicalIndex]
                let canonicalKind = normalizedSpreadsheetKind(cell(canonicalRow, typeIndex))
                let canonicalAccount = cell(canonicalRow, accountIndex)
                let canonicalCounterparty = cell(canonicalRow, categoryIndex ?? -1)
                let sourceAccount = canonicalKind == "transferout" ? canonicalAccount : canonicalCounterparty
                let destinationAccount = canonicalKind == "transferout"
                    ? canonicalCounterparty
                    : canonicalAccount
                let destinationFallback = counterpart.map { cell($0.element, accountIndex) } ?? ""
                let source = sourceAccount.isEmpty ? cell(row, accountIndex) : sourceAccount
                let destination = destinationAccount.isEmpty ? destinationFallback : destinationAccount

                let sourceHint = spreadsheetCurrencyHint(for: source)
                let destinationHint = spreadsheetCurrencyHint(for: destination)
                let primaryCurrency = spreadsheetCurrencyHint(for: currency) ?? .usd
                let usdAmount = usdIndex.map { cell(canonicalRow, $0) } ?? ""
                let hasCrossCurrencyHints = sourceHint != nil
                    && destinationHint != nil
                    && sourceHint != destinationHint
                let sourceCurrency = hasCrossCurrencyHints ? (sourceHint ?? primaryCurrency) : (sourceHint ?? primaryCurrency)
                let destinationCurrency = hasCrossCurrencyHints ? (destinationHint ?? primaryCurrency) : (destinationHint ?? primaryCurrency)
                let otherEndpointRow = counterpart.map {
                    $0.offset == canonicalIndex ? row : $0.element
                }
                let sourceEndpointRow: [String]? = canonicalKind == "transferout"
                    ? canonicalRow
                    : otherEndpointRow
                let destinationEndpointRow: [String]? = canonicalKind == "transferout"
                    ? otherEndpointRow
                    : canonicalRow
                let fallbackSourceAmount = hasCrossCurrencyHints && sourceCurrency == .usd && !usdAmount.isEmpty
                    ? usdAmount
                    : amount
                let fallbackDestinationAmount = hasCrossCurrencyHints && destinationCurrency == .usd && !usdAmount.isEmpty
                    ? usdAmount
                    : amount
                let sourceAmount = accountCurrencyAmount(in: sourceEndpointRow, currency: sourceHint)
                    ?? fallbackSourceAmount
                let destinationAmount = accountCurrencyAmount(in: destinationEndpointRow, currency: destinationHint)
                    ?? fallbackDestinationAmount
                let note = spreadsheetNote(row: canonicalRow, noteIndex: noteIndex, descriptionIndex: descriptionIndex)

                rows.append([
                    cell(canonicalRow, dateIndex),
                    TransactionKind.transfer.displayName,
                    sourceAmount,
                    sourceCurrency.rawValue,
                    "",
                    "",
                    source,
                    destination,
                    destinationAmount,
                    destinationCurrency.rawValue,
                    "",
                    note
                ])
                consumedTransferRows.insert(rowIndex)
                if let counterpart {
                    consumedTransferRows.insert(counterpart.offset)
                }
                continue
            }

            let category = cell(row, categoryIndex ?? -1)
            let subcategory = cell(row, subcategoryIndex ?? -1)
            let categoryPath = [category, subcategory]
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            let accountCurrency = spreadsheetCurrencyHint(for: cell(row, accountIndex))
            let isUSDTransactionInAnotherCurrencyAccount =
                spreadsheetCurrencyHint(for: cell(row, currencyIndex)) == .usd
                    && accountCurrency != nil
                    && accountCurrency != .usd
            let nativeAccountAmount = accountCurrencyAmount(in: row, currency: accountCurrency)
            let reportingAmount: String
            let reportingCurrency: String
            if isUSDTransactionInAnotherCurrencyAccount, let nativeAccountAmount, let accountCurrency {
                reportingAmount = nativeAccountAmount
                reportingCurrency = accountCurrency.rawValue
            } else {
                reportingAmount = usdIndex.map { cell(row, $0) } ?? ""
                reportingCurrency = reportingAmount.isEmpty ? "" : "USD"
            }
            rows.append([
                cell(row, dateIndex),
                kind.displayName,
                cell(row, amountIndex),
                cell(row, currencyIndex),
                reportingAmount,
                reportingCurrency,
                cell(row, accountIndex),
                "",
                "",
                "",
                categoryPath,
                spreadsheetNote(row: row, noteIndex: noteIndex, descriptionIndex: descriptionIndex)
            ])
        }

        guard !rows.isEmpty else { return nil }
        return ImportedTable(
            id: "\(table.id)-normalized",
            name: "\(table.name) (normalized)",
            columns: normalizedColumns,
            rows: rows
        )
    }

    private static func spreadsheetNote(
        row: [String],
        noteIndex: Int?,
        descriptionIndex: Int?
    ) -> String {
        [noteIndex.map { cell(row, $0) } ?? "", descriptionIndex.map { cell(row, $0) } ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func spreadsheetKind(_ rawValue: String) -> TransactionKind? {
        let value = normalizedSpreadsheetKind(rawValue)
        if value.contains("transfer") || value == "transferin" || value == "transferout" {
            return .transfer
        }
        if value.contains("income") || value == "income" {
            return .income
        }
        if value.contains("expense") || value == "exp" || value.contains("exp") {
            return .expense
        }
        return nil
    }

    private static func normalizedSpreadsheetKind(_ rawValue: String) -> String {
        normalize(rawValue)
    }

    private static func spreadsheetCurrencyHint(for accountName: String) -> LedgerCurrency? {
        let value = accountName.lowercased()
        if value.contains("lbp") || value.contains("leban") || value.contains("ل.ل") {
            return .lbp
        }
        if value.contains("usd") || value.contains("dollar") || value.contains("$") || value.contains("whish") {
            return .usd
        }
        if value.contains("eur") || value.contains("euro") || value.contains("€") {
            return .eur
        }
        return nil
    }

    private static func parseSQLite(url: URL) throws -> ImportedDocument {
        var database: OpaquePointer?
        let openResult = url.path.withCString { path in
            sqlite3_open_v2(path, &database, Int32(SQLITE_OPEN_READONLY), nil)
        }

        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "The SQLite file could not be opened."
            if let database {
                sqlite3_close(database)
            }
            throw FinanceImportError.invalidFile(message)
        }
        defer { sqlite3_close(database) }

        let tableQuery = try query(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        let nameIndex = tableQuery.columns.firstIndex { normalize($0) == "name" } ?? 0
        var tables: [ImportedTable] = []

        for tableRow in tableQuery.rows {
            guard tableRow.indices.contains(nameIndex), !tableRow[nameIndex].isEmpty else { continue }
            let tableName = tableRow[nameIndex]
            let quotedName = quoteIdentifier(tableName)
            let columnQuery = try query(database, sql: "PRAGMA table_info(\(quotedName))")
            guard let columnNameIndex = columnQuery.columns.firstIndex(where: { normalize($0) == "name" }) else { continue }
            let columns = columnQuery.rows.compactMap { row -> String? in
                guard row.indices.contains(columnNameIndex) else { return nil }
                return row[columnNameIndex]
            }
            guard !columns.isEmpty else { continue }

            let rowQuery = try query(database, sql: "SELECT * FROM \(quotedName) LIMIT 50000")
            guard !rowQuery.rows.isEmpty else { continue }
            tables.append(
                ImportedTable(
                    id: "sqlite-\(tableName)",
                    name: tableName,
                    columns: columns,
                    rows: rowQuery.rows
                )
            )
        }

        guard !tables.isEmpty else {
            throw FinanceImportError.invalidFile("The SQLite backup does not contain any readable tables.")
        }

        if let realbyteTable = makeRealbyteNormalizedTable(from: tables) {
            tables.insert(realbyteTable, at: 0)
        }

        return ImportedDocument(
            fileName: url.lastPathComponent,
            format: .sqlite,
            tables: tables
        )
    }

    private static func makeRealbyteNormalizedTable(from tables: [ImportedTable]) -> ImportedTable? {
        guard let transactionTable = tables.first(where: { table in
            let name = normalize(table.name)
            return name == "zinoutcome" || name == "inoutcome" || name.contains("inoutcome")
        }) else {
            return nil
        }

        let accountTable = tables.first { table in
            let name = normalize(table.name)
            return name == "zasset" || name == "asset" || name == "assets"
        }
        let categoryTable = tables.first { table in
            let name = normalize(table.name)
            return name == "zcategory" || name == "category" || name == "categories"
        }
        let currencyTable = tables.first { table in
            let name = normalize(table.name)
            return name == "zcurrency" || name == "currency" || name == "currencies"
        }

        let accountNames = referenceNames(from: accountTable)
        let categoryNames = referenceNames(from: categoryTable)
        let currencyNames = referenceNames(from: currencyTable)

        let dateIndex = columnIndex(in: transactionTable, aliases: ["ZTXDATESTR", "TXDATESTR", "DATESTR", "ZDATE", "DATE", "TXDATE"])
        let typeIndex = columnIndex(in: transactionTable, aliases: ["ZDO_TYPE", "DOTYPE", "TYPE", "KIND"])
        let amountIndex = columnIndex(in: transactionTable, aliases: ["ZAMOUNT", "AMOUNT", "VALUE", "MONEY"])
        let accountIndex = columnIndex(in: transactionTable, aliases: ["ZASSET_UID", "ASSET_UID", "ASSETUID", "ZASSET", "ASSET", "ACCOUNT_UID", "ACCOUNT"])
        let destinationIndex = columnIndex(in: transactionTable, aliases: ["ZTO_ASSET_UID", "TO_ASSET_UID", "TOASSETUID", "TOASSET", "DESTINATION"])
        let categoryIndex = columnIndex(in: transactionTable, aliases: ["ZCATEGORY_UID", "CATEGORY_UID", "CATEGORYUID", "ZCATEGORY", "CATEGORY"])
        let currencyIndex = columnIndex(in: transactionTable, aliases: ["ZCURRENCY_UID", "CURRENCY_UID", "CURRENCYUID", "ZCURRENCY", "CURRENCY"])
        let contentIndex = columnIndex(in: transactionTable, aliases: ["ZCONTENT", "CONTENT", "DESCRIPTION", "DETAILS"])
        let memoIndex = columnIndex(in: transactionTable, aliases: ["ZMEMO", "MEMO", "NOTE", "COMMENT"])
        let deletedIndex = columnIndex(in: transactionTable, aliases: ["ZISDEL", "ISDEL", "C_IS_DEL", "IS_DELETED"])

        guard let dateIndex, let amountIndex, let accountIndex else {
            return nil
        }

        let columns = ["Date", "Type", "Amount", "Currency", "Account", "Destination Account", "Category", "Note"]
        var rows: [[String]] = []

        for row in transactionTable.rows {
            if let deletedIndex, isTruthy(cell(row, deletedIndex)) { continue }

            let accountID = cell(row, accountIndex)
            let accountName = resolveReference(accountID, names: accountNames)
            let rawCurrency = currencyIndex.map { cell(row, $0) } ?? ""
            let accountCurrency = currencyNames[normalizedLookup(rawCurrency)] ?? rawCurrency
            let destinationID = destinationIndex.map { cell(row, $0) } ?? ""
            let destinationName = resolveReference(destinationID, names: accountNames)
            let categoryID = categoryIndex.map { cell(row, $0) } ?? ""
            let categoryName = resolveReference(categoryID, names: categoryNames)
            let content = contentIndex.map { cell(row, $0) } ?? ""
            let memo = memoIndex.map { cell(row, $0) } ?? ""
            let note = [content, memo].filter { !$0.isEmpty }.joined(separator: " · ")
            let kind = realbyteKind(typeIndex.map { cell(row, $0) } ?? "")

            rows.append([
                cell(row, dateIndex),
                kind,
                cell(row, amountIndex),
                accountCurrency,
                accountName,
                destinationName,
                categoryName,
                note
            ])
        }

        guard !rows.isEmpty else { return nil }
        return ImportedTable(
            id: "realbyte-normalized",
            name: "Money Manager transactions (normalized)",
            columns: columns,
            rows: rows
        )
    }

    private static func referenceNames(from table: ImportedTable?) -> [String: String] {
        guard let table,
              let identifierIndex = columnIndex(in: table, aliases: ["ZUID", "UID", "ID", "Z_PK", "PK", "UUID"]),
              let nameIndex = columnIndex(in: table, aliases: ["ZNIC_NAME", "NIC_NAME", "ZNAME", "NAME", "TITLE", "ZTITLE", "SYMBOL", "ISO", "CODE"]) else {
            return [:]
        }

        var names: [String: String] = [:]
        for row in table.rows {
            let identifier = cell(row, identifierIndex)
            let name = cell(row, nameIndex)
            guard !identifier.isEmpty, !name.isEmpty else { continue }
            names[normalizedLookup(identifier)] = name
        }
        return names
    }

    private static func query(_ database: OpaquePointer, sql: String) throws -> (columns: [String], rows: [[String]]) {
        var statement: OpaquePointer?
        let prepareResult = sql.withCString { query in
            sqlite3_prepare_v2(database, query, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw FinanceImportError.invalidFile(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0..<columnCount).map { index in
            String(cString: sqlite3_column_name(statement, Int32(index)))
        }

        var rows: [[String]] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                rows.append((0..<columnCount).map { value(statement, index: $0) })
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                throw FinanceImportError.invalidFile(String(cString: sqlite3_errmsg(database)))
            }
        }

        return (columns, rows)
    }

    private static func value(_ statement: OpaquePointer, index: Int) -> String {
        let columnIndex = Int32(index)
        switch sqlite3_column_type(statement, columnIndex) {
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, columnIndex))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, columnIndex))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, columnIndex) else { return "" }
            return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
        case SQLITE_BLOB:
            return "<blob>"
        default:
            return ""
        }
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func parseDelimitedRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = Array(text)
        characters.append("\n")
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case delimiter:
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field.trimmingCharacters(in: .init(charactersIn: "\r")))
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) {
                        rows.append(row)
                    }
                    row = []
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        return rows
    }

    private static func detectDelimiter(in text: String) -> Character {
        let sample = text.split(whereSeparator: \Character.isNewline).prefix(10).joined(separator: "\n")
        let candidates: [Character] = ["\t", ",", ";", "|"]
        return candidates.max { left, right in
            sample.filter { $0 == left }.count < sample.filter { $0 == right }.count
        } ?? ","
    }

    private static func uniqueHeaders(_ headers: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return headers.enumerated().map { index, rawHeader in
            let trimmed = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Column \(index + 1)" : trimmed
            let count = counts[base, default: 0]
            counts[base] = count + 1
            return count == 0 ? base : "\(base) \(count + 1)"
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        return String(data: data, encoding: .utf16BigEndian)
    }

    private static func stringifyJSONValue(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            guard JSONSerialization.isValidJSONObject(value as Any),
                  let data = try? JSONSerialization.data(withJSONObject: value as Any) else {
                return String(describing: value)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func columnIndex(in table: ImportedTable, aliases: [String]) -> Int? {
        let normalizedAliases = aliases.map(normalize)
        return table.columns.firstIndex { column in
            let normalizedColumn = normalize(column)
            return normalizedAliases.contains { alias in
                normalizedColumn == alias || normalizedColumn.contains(alias)
            }
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedLookup(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func cell(_ row: [String], _ index: Int) -> String {
        row.indices.contains(index) ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private static func resolveReference(_ rawValue: String, names: [String: String]) -> String {
        guard !rawValue.isEmpty else { return "" }
        return names[normalizedLookup(rawValue)] ?? rawValue
    }

    private static func isTruthy(_ value: String) -> Bool {
        ["1", "true", "yes"].contains(value.lowercased())
    }

    private static func realbyteKind(_ rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = Int(normalized) {
            switch code {
            case 0:
                return "Income"
            case 1:
                return "Expense"
            case 7, 8:
                return "Transfer"
            default:
                break
            }
        }
        if normalized.contains("income") || normalized.contains("salary") || normalized.contains("deposit") {
            return "Income"
        }
        if normalized.contains("transfer") || normalized.contains("move") {
            return "Transfer"
        }
        return "Expense"
    }
}

private struct XLSXSheetReference {
    let name: String
    let relationshipID: String
}

private final class XLSXWorkbookDelegate: NSObject, XMLParserDelegate {
    var sheets: [XLSXSheetReference] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet",
              let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else {
            return
        }
        sheets.append(XLSXSheetReference(name: name, relationshipID: relationshipID))
    }
}

private final class XLSXRelationshipsDelegate: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship",
              let identifier = attributeDict["Id"],
              let target = attributeDict["Target"] else {
            return
        }
        targets[identifier] = target
    }
}

private final class XLSXSharedStringsDelegate: NSObject, XMLParserDelegate {
    var values: [String] = []
    private var currentValue = ""
    private var isCapturingText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            currentValue = ""
        } else if elementName == "t" {
            isCapturingText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCapturingText {
            currentValue.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" {
            isCapturingText = false
        } else if elementName == "si" {
            values.append(currentValue)
        }
    }
}

private final class XLSXWorksheetDelegate: NSObject, XMLParserDelegate {
    private enum CaptureTarget {
        case value
        case inlineText
    }

    let sharedStrings: [String]
    var rows: [[Int: String]] = []

    private var currentRow: [Int: String] = [:]
    private var currentCellColumn: Int?
    private var currentCellType = ""
    private var currentValue = ""
    private var currentInlineText = ""
    private var captureTarget: CaptureTarget?

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            currentRow = [:]
        case "c":
            currentCellColumn = Self.columnIndex(from: attributeDict["r"] ?? "")
            currentCellType = attributeDict["t"] ?? ""
            currentValue = ""
            currentInlineText = ""
        case "v":
            captureTarget = .value
            currentValue = ""
        case "t":
            captureTarget = .inlineText
            currentInlineText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch captureTarget {
        case .value:
            currentValue.append(string)
        case .inlineText:
            currentInlineText.append(string)
        case nil:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v", "t":
            captureTarget = nil
        case "c":
            if let column = currentCellColumn {
                currentRow[column] = resolvedCellValue()
            }
            currentCellColumn = nil
            currentCellType = ""
            currentValue = ""
            currentInlineText = ""
        case "row":
            rows.append(currentRow)
            currentRow = [:]
        default:
            break
        }
    }

    private func resolvedCellValue() -> String {
        switch currentCellType {
        case "s":
            guard let index = Int(currentValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  sharedStrings.indices.contains(index) else {
                return currentValue
            }
            return sharedStrings[index]
        case "inlineStr":
            return currentInlineText
        case "b":
            return currentValue == "1" ? "TRUE" : "FALSE"
        default:
            return currentValue.isEmpty ? currentInlineText : currentValue
        }
    }

    private static func columnIndex(from reference: String) -> Int? {
        let letters = reference.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }

        var number = 0
        for letter in letters {
            guard let scalar = String(letter).uppercased().unicodeScalars.first,
                  scalar.value >= 65,
                  scalar.value <= 90 else {
                return nil
            }
            number = number * 26 + Int(scalar.value - 64)
        }
        return number - 1
    }
}

private func financeImportLookupKey(_ name: String) -> String {
    name.folding(options: [.caseInsensitive], locale: nil)
}

enum FinanceImportBuilder {
    private struct AccountLookup {
        private var accountsByName: [String: [Account]] = [:]
        private var accountsByID: [UUID: Account] = [:]

        init(_ accounts: [Account]) {
            for account in accounts {
                insert(account)
            }
        }

        mutating func insert(_ account: Account) {
            accountsByName[financeImportLookupKey(account.name), default: []].append(account)
            if accountsByID[account.id] == nil {
                accountsByID[account.id] = account
            }
        }

        func first(named name: String, currency: LedgerCurrency? = nil) -> Account? {
            accountsByName[financeImportLookupKey(name)]?.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && (currency == nil || $0.currency == currency)
            }
        }

        func account(id: UUID) -> Account? {
            accountsByID[id]
        }
    }

    private struct CategoryLookupKey: Hashable {
        let parentID: UUID?
        let name: String
    }

    private struct CategoryLookup {
        private var categoriesByParentAndName: [CategoryLookupKey: [LedgerCategory]] = [:]

        init(_ categories: [LedgerCategory]) {
            for category in categories {
                insert(category)
            }
        }

        mutating func insert(_ category: LedgerCategory) {
            let key = CategoryLookupKey(
                parentID: category.parentID,
                name: financeImportLookupKey(category.name)
            )
            categoriesByParentAndName[key, default: []].append(category)
        }

        func first(
            named name: String,
            parentID: UUID?,
            excludingArchived: Bool = false
        ) -> LedgerCategory? {
            let key = CategoryLookupKey(parentID: parentID, name: financeImportLookupKey(name))
            return categoriesByParentAndName[key]?.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && (!excludingArchived || !$0.isArchived)
            }
        }
    }

    static func accountImportCandidates(
        table: ImportedTable,
        mapping: [ImportField: String?]
    ) -> [ImportAccountCandidate] {
        struct AccumulatedCandidate {
            var name: String
            var currencies: [String] = []
            var types: [String] = []
        }

        var accumulated: [String: AccumulatedCandidate] = [:]

        func addCandidate(
            name rawName: String,
            currency rawCurrency: String,
            type rawType: String
        ) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }

            let key = ImportAccountCandidate.key(for: name)
            var candidate = accumulated[key] ?? AccumulatedCandidate(name: name)
            if !rawCurrency.isEmpty, !candidate.currencies.contains(rawCurrency) {
                candidate.currencies.append(rawCurrency)
            }
            if !rawType.isEmpty, !candidate.types.contains(rawType) {
                candidate.types.append(rawType)
            }
            accumulated[key] = candidate
        }

        for row in table.rows {
            if Task.isCancelled { return [] }
            addCandidate(
                name: value(for: .account, in: row, table: table, mapping: mapping),
                currency: value(for: .currency, in: row, table: table, mapping: mapping),
                type: value(for: .accountType, in: row, table: table, mapping: mapping)
            )
            addCandidate(
                name: value(for: .destinationAccount, in: row, table: table, mapping: mapping),
                currency: value(for: .destinationCurrency, in: row, table: table, mapping: mapping),
                type: value(for: .destinationAccountType, in: row, table: table, mapping: mapping)
            )
        }

        return accumulated.values
            .map {
                ImportAccountCandidate(
                    name: $0.name,
                    observedCurrencies: $0.currencies,
                    observedTypes: $0.types
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func build(
        table: ImportedTable,
        mapping: [ImportField: String?],
        options: ImportOptions,
        existing: FinanceData
    ) throws -> FinanceImportResult {
        guard mapping[.date] ?? nil != nil else { throw FinanceImportError.missingMapping(.date) }
        guard mapping[.amount] ?? nil != nil else { throw FinanceImportError.missingMapping(.amount) }

        var importedAccounts: [Account] = []
        var importedCategories: [LedgerCategory] = []
        var importedExchangeRates: [ExchangeRate] = []
        var accountLookup = AccountLookup(existing.accounts)
        var categoryLookup = CategoryLookup(existing.categories)
        var availableExchangeRates = existing.exchangeRates
        var importedTransactions: [LedgerTransaction] = []
        var warnings: [String] = []
        var skippedRows = 0
        let isoDateFormatter = ISO8601DateFormatter()
        let dateFormatters = [
            "yyyy-MM-dd",
            "yyyy.MM.dd",
            "yy.MM.dd",
            "yyyy/MM/dd",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
            "dd-MM-yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy.MM.dd HH:mm:ss"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }

        for (rowOffset, row) in table.rows.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            do {
                let date = try parseDate(
                    value(for: .date, in: row, table: table, mapping: mapping),
                    isoFormatter: isoDateFormatter,
                    dateFormatters: dateFormatters
                )
                let rawAmount = value(for: .amount, in: row, table: table, mapping: mapping)
                let accountName = value(for: .account, in: row, table: table, mapping: mapping)
                let currencyValue = value(for: .currency, in: row, table: table, mapping: mapping)
                let explicitCurrency = currencyValue.isEmpty
                    ? nil
                    : parseCurrency(currencyValue, default: options.defaultCurrency)
                let knownSourceAccount = matchingAccount(
                    named: accountName,
                    defaultID: options.defaultAccountID,
                    in: accountLookup
                )
                let preferredCurrency = explicitCurrency
                    ?? knownSourceAccount?.currency
                    ?? accountSuggestion(for: accountName, in: options.accountSuggestions)?.currency
                    ?? inferredCurrency(for: accountName, fallback: options.defaultCurrency)
                let inputCurrency = explicitCurrency ?? preferredCurrency
                let signedAmount = try parseAmount(rawAmount, currency: inputCurrency)
                guard signedAmount.minorUnits != 0 else {
                    throw FinanceImportError.row("The amount is zero.")
                }

                let kind = parseKind(
                    value(for: .kind, in: row, table: table, mapping: mapping),
                    default: signedAmount.minorUnits < 0 ? .expense : options.defaultKind
                )
                let account = try resolveAccount(
                    name: accountName,
                    currency: preferredCurrency,
                    explicitCurrency: explicitCurrency,
                    type: parseAccountType(value(for: .accountType, in: row, table: table, mapping: mapping))
                        ?? parseAccountType(accountName)
                        ?? accountSuggestion(for: accountName, in: options.accountSuggestions)?.type,
                    options: options,
                    accountLookup: &accountLookup,
                    imported: &importedAccounts
                )
                let currency = account.currency
                let importedAmount = Money(
                    currency: inputCurrency,
                    minorUnits: Swift.abs(signedAmount.minorUnits)
                )
                let rawReportingAmount = value(for: .baseAmount, in: row, table: table, mapping: mapping)
                let reportingAmount: Money?
                if rawReportingAmount.isEmpty {
                    reportingAmount = nil
                } else {
                    let rawReportingCurrency = value(
                        for: .baseCurrency,
                        in: row,
                        table: table,
                        mapping: mapping
                    )
                    let reportingCurrency = rawReportingCurrency.isEmpty
                        ? options.defaultCurrency
                        : parseCurrency(rawReportingCurrency, default: options.defaultCurrency)
                    let parsedReportingAmount = try parseAmount(
                        rawReportingAmount,
                        currency: reportingCurrency
                    )
                    reportingAmount = Money(
                        currency: reportingCurrency,
                        minorUnits: Swift.abs(parsedReportingAmount.minorUnits)
                    )
                }
                let categoryID = try resolveCategory(
                    value(for: .category, in: row, table: table, mapping: mapping),
                    kind: kind,
                    options: options,
                    categoryLookup: &categoryLookup,
                    imported: &importedCategories
                )
                let noteValue = value(for: .note, in: row, table: table, mapping: mapping)
                let note = noteValue.isEmpty ? kind.displayName : noteValue

                var outflows: [MoneyMovement] = []
                var inflows: [MoneyMovement] = []
                var amount: Money
                var exchangeRate: ExchangeRate?
                switch kind {
                case .expense:
                    amount = importedAmount
                    exchangeRate = try exchangeRateForImportedMovement(
                        amount,
                        accountCurrency: currency,
                        reportingAmount: reportingAmount,
                        using: availableExchangeRates
                    )
                    outflows = [MoneyMovement(accountID: account.id, money: amount)]
                case .income:
                    amount = importedAmount
                    exchangeRate = try exchangeRateForImportedMovement(
                        amount,
                        accountCurrency: currency,
                        reportingAmount: reportingAmount,
                        using: availableExchangeRates
                    )
                    inflows = [MoneyMovement(accountID: account.id, money: amount)]
                case .transfer:
                    let destinationName = value(for: .destinationAccount, in: row, table: table, mapping: mapping)
                    let destinationCurrencyValue = value(
                        for: .destinationCurrency,
                        in: row,
                        table: table,
                        mapping: mapping
                    )
                    let explicitDestinationCurrency = destinationCurrencyValue.isEmpty
                        ? nil
                        : parseCurrency(destinationCurrencyValue, default: currency)
                    let knownDestinationAccount = matchingAccount(
                        named: destinationName,
                        defaultID: options.defaultDestinationAccountID,
                        in: accountLookup
                    )
                    let destinationCurrency = knownDestinationAccount?.currency
                        ?? explicitDestinationCurrency
                        ?? accountSuggestion(
                            for: destinationName,
                            in: options.accountSuggestions
                        )?.currency
                        ?? inferredCurrency(for: destinationName, fallback: currency)
                    let destinationAmountValue = value(for: .destinationAmount, in: row, table: table, mapping: mapping)
                    let destination = try resolveDestinationAccount(
                        name: destinationName,
                        currency: destinationCurrency,
                        explicitCurrency: explicitDestinationCurrency,
                        type: parseAccountType(
                            value(for: .destinationAccountType, in: row, table: table, mapping: mapping)
                        ) ?? parseAccountType(destinationName) ?? accountSuggestion(
                            for: destinationName,
                            in: options.accountSuggestions
                        )?.type,
                        options: options,
                        accountLookup: &accountLookup,
                        imported: &importedAccounts
                    )
                    let destinationMoneyCurrency = destination.currency
                    let destinationAmount: Money

                    if currency == destinationMoneyCurrency {
                        amount = try convertedAmount(
                            importedAmount,
                            to: currency,
                            using: availableExchangeRates
                        )
                        if destinationAmountValue.isEmpty {
                            destinationAmount = amount
                        } else {
                            let parsedDestinationAmount = Money(
                                currency: destinationMoneyCurrency,
                                minorUnits: Swift.abs(
                                    try parseAmount(
                                        destinationAmountValue,
                                        currency: destinationMoneyCurrency
                                    ).minorUnits
                                )
                            )
                            destinationAmount = try convertedAmount(
                                parsedDestinationAmount,
                                to: destinationMoneyCurrency,
                                using: availableExchangeRates
                            )
                        }
                    } else if !destinationAmountValue.isEmpty {
                        let parsedDestinationAmount = Money(
                            currency: destinationMoneyCurrency,
                            minorUnits: Swift.abs(
                                try parseAmount(
                                    destinationAmountValue,
                                    currency: destinationMoneyCurrency
                                ).minorUnits
                            )
                        )
                        amount = try convertedAmount(
                            importedAmount,
                            to: currency,
                            using: availableExchangeRates
                        )
                        destinationAmount = parsedDestinationAmount
                        exchangeRate = inferredExchangeRate(from: amount, to: destinationAmount)
                    } else if importedAmount.currency == destinationMoneyCurrency {
                        guard let rate = storedExchangeRate(
                            from: currency,
                            to: destinationMoneyCurrency,
                            in: availableExchangeRates
                        ) else {
                            throw FinanceImportError.row(
                                "No exchange rate is available to convert the imported destination amount from \(destinationMoneyCurrency.rawValue) to \(currency.rawValue)."
                            )
                        }
                        destinationAmount = importedAmount
                        guard let convertedSourceAmount = convertedAmount(
                            destinationAmount,
                            to: currency,
                            using: rate
                        ) else {
                            throw FinanceImportError.row(
                                "The exchange rate could not convert \(destinationMoneyCurrency.rawValue) to \(currency.rawValue)."
                            )
                        }
                        amount = convertedSourceAmount
                        exchangeRate = rate
                    } else {
                        guard let rate = storedExchangeRate(
                            from: currency,
                            to: destinationMoneyCurrency,
                            in: availableExchangeRates
                        ) else {
                            throw FinanceImportError.row(
                                "No exchange rate is available to convert the imported source amount from \(currency.rawValue) to \(destinationMoneyCurrency.rawValue)."
                            )
                        }
                        amount = try convertedAmount(
                            importedAmount,
                            to: currency,
                            using: availableExchangeRates
                        )
                        guard let convertedDestinationAmount = convertedAmount(
                            amount,
                            to: destinationMoneyCurrency,
                            using: rate
                        ) else {
                            throw FinanceImportError.row(
                                "The exchange rate could not convert \(currency.rawValue) to \(destinationMoneyCurrency.rawValue)."
                            )
                        }
                        destinationAmount = convertedDestinationAmount
                        exchangeRate = rate
                    }

                    if currency != destinationMoneyCurrency, exchangeRate == nil {
                        guard let inferredRate = inferredExchangeRate(from: amount, to: destinationAmount) else {
                            throw FinanceImportError.row(
                                "The cross-currency transfer does not contain positive amounts for both currencies."
                            )
                        }
                        exchangeRate = inferredRate
                    }
                    outflows = [MoneyMovement(accountID: account.id, money: amount)]
                    inflows = [MoneyMovement(accountID: destination.id, money: destinationAmount)]
                }

                if let exchangeRate,
                   !importedExchangeRates.contains(where: {
                       $0.baseCurrency == exchangeRate.baseCurrency
                           && $0.quoteCurrency == exchangeRate.quoteCurrency
                   }) {
                    importedExchangeRates.removeAll {
                        Set([$0.baseCurrency, $0.quoteCurrency]) == Set([
                            exchangeRate.baseCurrency,
                            exchangeRate.quoteCurrency
                        ])
                    }
                    if availableExchangeRates.count > existing.exchangeRates.count {
                        availableExchangeRates.removeSubrange(
                            existing.exchangeRates.count..<availableExchangeRates.endIndex
                        )
                    }
                    availableExchangeRates.append(contentsOf: importedExchangeRates)
                    importedExchangeRates.append(exchangeRate)
                    availableExchangeRates.append(exchangeRate)
                }

                importedTransactions.append(
                    LedgerTransaction(
                        date: date,
                        note: note,
                        kind: kind,
                        categoryID: categoryID,
                        outflows: outflows,
                        inflows: inflows,
                        exchangeRate: exchangeRate
                    )
                )
            } catch {
                skippedRows += 1
                warnings.append("Row \(rowOffset + 2): \(error.localizedDescription)")
            }
        }

        guard !importedTransactions.isEmpty else {
            throw FinanceImportError.noImportableRows
        }

        return FinanceImportResult(
            data: FinanceData(
                accounts: importedAccounts,
                categories: importedCategories,
                transactions: importedTransactions,
                exchangeRates: importedExchangeRates
            ),
            importedRows: importedTransactions.count,
            skippedRows: skippedRows,
            warnings: warnings
        )
    }

    private static func value(
        for field: ImportField,
        in row: [String],
        table: ImportedTable,
        mapping: [ImportField: String?]
    ) -> String {
        guard let sourceColumn = mapping[field] ?? nil,
              let index = table.columns.firstIndex(of: sourceColumn),
              row.indices.contains(index) else {
            return ""
        }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchingAccount(
        named rawName: String,
        defaultID: UUID?,
        in accounts: AccountLookup
    ) -> Account? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return accounts.first(named: name)
        }
        guard let defaultID else { return nil }
        return accounts.account(id: defaultID)
    }

    private static func storedExchangeRate(
        from baseCurrency: LedgerCurrency,
        to quoteCurrency: LedgerCurrency,
        in rates: [ExchangeRate]
    ) -> ExchangeRate? {
        guard baseCurrency != quoteCurrency else { return nil }

        if let exact = rates.first(where: {
            $0.baseCurrency == baseCurrency && $0.quoteCurrency == quoteCurrency
        }) {
            return exact
        }

        guard let reverse = rates.first(where: {
            $0.baseCurrency == quoteCurrency && $0.quoteCurrency == baseCurrency
        }), reverse.quoteUnitsPerBaseUnit > 0 else {
            return nil
        }
        return ExchangeRate(
            baseCurrency: baseCurrency,
            quoteCurrency: quoteCurrency,
            quoteUnitsPerBaseUnit: Decimal(1) / reverse.quoteUnitsPerBaseUnit
        )
    }

    private static func convertedAmount(
        _ money: Money,
        to currency: LedgerCurrency,
        using rates: [ExchangeRate]
    ) throws -> Money {
        guard money.currency != currency else { return money }
        guard let rate = storedExchangeRate(from: money.currency, to: currency, in: rates),
              let converted = convertedAmount(money, to: currency, using: rate) else {
            throw FinanceImportError.row(
                "No exchange rate is available to convert \(money.currency.rawValue) to \(currency.rawValue)."
            )
        }
        return converted
    }

    private static func convertedAmount(
        _ money: Money,
        to currency: LedgerCurrency,
        using rate: ExchangeRate
    ) -> Money? {
        guard rate.quoteUnitsPerBaseUnit > 0 else { return nil }

        let sourceUnits = Decimal(money.minorUnits) / Decimal(money.currency.minorUnitScale)
        let targetUnits: Decimal
        if money.currency == rate.baseCurrency && currency == rate.quoteCurrency {
            targetUnits = sourceUnits * rate.quoteUnitsPerBaseUnit
        } else if money.currency == rate.quoteCurrency && currency == rate.baseCurrency {
            targetUnits = sourceUnits / rate.quoteUnitsPerBaseUnit
        } else {
            return nil
        }

        let targetMinorUnits = targetUnits * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        var value = targetMinorUnits
        NSDecimalRound(&rounded, &value, 0, .plain)
        let minorUnits = NSDecimalNumber(decimal: rounded).int64Value
        guard minorUnits > 0 else { return nil }
        return Money(currency: currency, minorUnits: minorUnits)
    }

    private static func exchangeRateForImportedMovement(
        _ amount: Money,
        accountCurrency: LedgerCurrency,
        reportingAmount: Money?,
        using rates: [ExchangeRate]
    ) throws -> ExchangeRate? {
        if amount.currency == accountCurrency {
            guard let reportingAmount,
                  reportingAmount.currency != amount.currency else {
                return nil
            }
            return inferredExchangeRate(from: amount, to: reportingAmount)
        }

        if let reportingAmount,
           reportingAmount.currency != amount.currency,
           let reportingRate = inferredExchangeRate(from: amount, to: reportingAmount),
           convertedAmount(amount, to: accountCurrency, using: reportingRate) != nil {
            return reportingRate
        }

        guard let accountRate = storedExchangeRate(
            from: amount.currency,
            to: accountCurrency,
            in: rates
        ) else {
            throw FinanceImportError.row(
                "No exchange rate is available to record the imported \(amount.currency.rawValue) amount in the \(accountCurrency.rawValue) account."
            )
        }
        return accountRate
    }

    private static func accountSuggestion(
        for name: String,
        in suggestions: [String: ImportAccountSuggestion]
    ) -> ImportAccountSuggestion? {
        let key = ImportAccountCandidate.key(for: name)
        return suggestions[key]
            ?? suggestions.first(where: { ImportAccountCandidate.key(for: $0.key) == key })?.value
    }

    private static func resolveAccount(
        name rawName: String,
        currency: LedgerCurrency,
        explicitCurrency: LedgerCurrency?,
        type: AccountType?,
        options: ImportOptions,
        accountLookup: inout AccountLookup,
        imported: inout [Account]
    ) throws -> Account {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty, let defaultAccountID = options.defaultAccountID,
           let account = accountLookup.account(id: defaultAccountID) {
            return account
        }

        if !name.isEmpty {
            if explicitCurrency != nil, let account = accountLookup.first(named: name, currency: currency) {
                return account
            }
            if let account = accountLookup.first(named: name) {
                return account
            }
        }

        guard !name.isEmpty, options.createMissingAccounts else {
            throw FinanceImportError.row("Map an account column or choose a default account.")
        }

        let account = Account(
            name: name,
            type: type ?? inferredAccountType(for: name),
            currency: currency,
            openingBalance: Money(currency: currency, minorUnits: 0)
        )
        imported.append(account)
        accountLookup.insert(account)
        return account
    }

    private static func resolveDestinationAccount(
        name rawName: String,
        currency: LedgerCurrency,
        explicitCurrency: LedgerCurrency?,
        type: AccountType?,
        options: ImportOptions,
        accountLookup: inout AccountLookup,
        imported: inout [Account]
    ) throws -> Account {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty, let defaultAccountID = options.defaultDestinationAccountID,
           let account = accountLookup.account(id: defaultAccountID) {
            return account
        }
        return try resolveAccount(
            name: name,
            currency: currency,
            explicitCurrency: explicitCurrency,
            type: type,
            options: ImportOptions(
                defaultKind: options.defaultKind,
                defaultCurrency: options.defaultCurrency,
                defaultAccountID: options.defaultDestinationAccountID,
                defaultDestinationAccountID: nil,
                createMissingAccounts: options.createMissingAccounts,
                createMissingCategories: options.createMissingCategories,
                accountSuggestions: options.accountSuggestions
            ),
            accountLookup: &accountLookup,
            imported: &imported
        )
    }

    private static func resolveCategory(
        _ rawValue: String,
        kind: TransactionKind,
        options: ImportOptions,
        categoryLookup: inout CategoryLookup,
        imported: inout [LedgerCategory]
    ) throws -> UUID? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultCategoryID(
                for: kind,
                options: options,
                categoryLookup: &categoryLookup,
                imported: &imported
            )
        }

        let parts = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/>"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return defaultCategoryID(
                for: kind,
                options: options,
                categoryLookup: &categoryLookup,
                imported: &imported
            )
        }

        var parentID: UUID?
        for part in parts {
            if let category = categoryLookup.first(named: part, parentID: parentID) {
                parentID = category.id
                continue
            }

            guard options.createMissingCategories else {
                throw FinanceImportError.row("Category \(part) does not exist and creating categories is disabled.")
            }

            let includeInTotals = !(parentID == nil
                && part.caseInsensitiveCompare("Modified Bal.") == .orderedSame)
            let category = LedgerCategory(
                name: part,
                parentID: parentID,
                includeInTotals: includeInTotals
            )
            imported.append(category)
            categoryLookup.insert(category)
            parentID = category.id
        }
        return parentID
    }

    private static func defaultCategoryID(
        for kind: TransactionKind,
        options: ImportOptions,
        categoryLookup: inout CategoryLookup,
        imported: inout [LedgerCategory]
    ) -> UUID? {
        guard kind == .expense else { return nil }

        if let other = categoryLookup.first(named: "Other", parentID: nil, excludingArchived: true) {
            return other.id
        }

        guard options.createMissingCategories else { return nil }
        let other = LedgerCategory(name: "Other")
        imported.append(other)
        categoryLookup.insert(other)
        return other.id
    }

    private static func inferredExchangeRate(
        from base: Money,
        to quote: Money
    ) -> ExchangeRate? {
        guard base.minorUnits > 0, quote.minorUnits > 0 else { return nil }

        let baseUnits = Decimal(base.minorUnits) / Decimal(base.currency.minorUnitScale)
        let quoteUnits = Decimal(quote.minorUnits) / Decimal(quote.currency.minorUnitScale)
        guard baseUnits > 0, quoteUnits > 0 else { return nil }

        return ExchangeRate(
            baseCurrency: base.currency,
            quoteCurrency: quote.currency,
            quoteUnitsPerBaseUnit: quoteUnits / baseUnits
        )
    }

    private static func parseDate(
        _ rawValue: String,
        isoFormatter: ISO8601DateFormatter,
        dateFormatters: [DateFormatter]
    ) throws -> Date {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FinanceImportError.row("The date is empty.") }

        if let numeric = Double(value) {
            if numeric > 1_000_000_000 {
                return Date(timeIntervalSince1970: numeric)
            }
            if numeric >= 20_000 && numeric <= 100_000 {
                return Date(timeIntervalSince1970: (numeric - 25_569) * 86_400)
            }
            if numeric > 100_000 {
                return Date(timeIntervalSinceReferenceDate: numeric)
            }
        }

        if let date = isoFormatter.date(from: value) { return date }

        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }

        throw FinanceImportError.row("Could not read date \"\(value)\".")
    }

    private static func parseAmount(_ rawValue: String, currency: LedgerCurrency) throws -> Money {
        let hasParentheses = rawValue.contains("(") && rawValue.contains(")")
        let filtered = rawValue.filter { character in
            character.isNumber || character == "." || character == "-" || character == "+"
        }
        let normalized = hasParentheses && !filtered.hasPrefix("-") ? "-\(filtered)" : String(filtered)
        guard let amount = Money.parse(
            normalized,
            currency: currency,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw FinanceImportError.row("Could not read amount \"\(rawValue)\".")
        }
        return amount
    }

    private static func inferredCurrency(
        for rawName: String,
        fallback: LedgerCurrency
    ) -> LedgerCurrency {
        let value = rawName.lowercased()
        if value.contains("lbp") || value.contains("leban") || value.contains("lira") || value.contains("ل.ل") {
            return .lbp
        }
        if value.contains("usd") || value.contains("dollar") || value.contains("$") || value.contains("whish") {
            return .usd
        }
        if value.contains("eur") || value.contains("euro") || value.contains("€") {
            return .eur
        }
        return fallback
    }

    private static func parseAccountType(_ rawValue: String) -> AccountType? {
        let value = rawValue.lowercased()
        guard !value.isEmpty else { return nil }

        if value.contains("loan") || value.contains("debt") || value.contains("credit") || value.contains("mortgage") {
            return .loan
        }
        if value.contains("bank") || value.contains("checking") || value.contains("chequing")
            || value.contains("savings") || value.contains("saving") {
            return .bankAccount
        }
        if value.contains("invest") || value.contains("broker") || value.contains("stock")
            || value.contains("portfolio") {
            return .investment
        }
        if value.contains("asset") || value.contains("property") || value.contains("house")
            || value.contains("home") || value.contains("vehicle") || value.contains("car")
            || value.contains("gold") || value.contains("silver") || value.contains("coin")
            || value.contains("bullion") || value.contains("jewelry") || value.contains("jewellery")
            || value.contains("precious metal") || value.contains("real estate") || value.contains("land")
            || value.contains("collectible") || value.contains("good") || value.contains("goods")
            || value.contains("inventory") || value.contains("commodity") {
            return .physicalAsset
        }
        if value.contains("cash") || value.contains("wallet") || value.contains("petty") {
            return .cash
        }
        return nil
    }

    private static func inferredAccountType(for rawName: String) -> AccountType {
        parseAccountType(rawName) ?? .cash
    }

    private static func parseCurrency(_ rawValue: String, default defaultCurrency: LedgerCurrency) -> LedgerCurrency {
        let value = rawValue.lowercased()
        if value.contains("usd") || value.contains("dollar") || value.contains("$") { return .usd }
        if value.contains("lbp") || value.contains("leban") || value.contains("ل.ل") { return .lbp }
        if value.contains("eur") || value.contains("euro") || value.contains("€") { return .eur }
        return defaultCurrency
    }

    private static func parseKind(_ rawValue: String, default defaultKind: TransactionKind) -> TransactionKind {
        let value = rawValue.lowercased()
        if value.contains("transfer") || value.contains("move") { return .transfer }
        if value.contains("income") || value.contains("salary") || value.contains("deposit") || value == "0" { return .income }
        if value.contains("expense") || value.contains("spend") || value.contains("withdraw") || value.contains("debit") || value == "1" { return .expense }
        if value == "7" || value == "8" { return .transfer }
        return defaultKind
    }
}

enum LedgerCSVExporter {
    static func data(for financeData: FinanceData) -> Data {
        var lines = ["Date,Type,Amount,Currency,Account,Destination Account,Category,Note"]
        let accountsByID = Dictionary(uniqueKeysWithValues: financeData.accounts.map { ($0.id, $0) })

        for transaction in financeData.transactions.sorted(by: { $0.date < $1.date }) {
            let movements: [(MoneyMovement, String)] = transaction.kind == .income
                ? transaction.inflows.map { ($0, "") }
                : transaction.outflows.map { movement in
                    let destination = transaction.inflows.first.flatMap { accountsByID[$0.accountID]?.name } ?? ""
                    return (movement, destination)
                }

            for (movement, destination) in movements {
                let accountName = accountsByID[movement.accountID]?.name ?? ""
                let category = categoryPath(for: transaction.categoryID, categories: financeData.categories)
                let values = [
                    transaction.date.formatted(.iso8601.year().month().day()),
                    transaction.kind.displayName,
                    Money(currency: movement.money.currency, minorUnits: Swift.abs(movement.money.minorUnits)).stableFormatted,
                    movement.money.currency.rawValue,
                    accountName,
                    destination,
                    category,
                    transaction.note
                ]
                lines.append(values.map(escape).joined(separator: ","))
            }
        }

        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func categoryPath(for categoryID: UUID?, categories: [LedgerCategory]) -> String {
        guard let categoryID else { return "" }
        var names: [String] = []
        var currentID: UUID? = categoryID
        var visited: Set<UUID> = []
        while let id = currentID,
              !visited.contains(id),
              let category = categories.first(where: { $0.id == id }) {
            visited.insert(id)
            names.insert(category.name, at: 0)
            currentID = category.parentID
        }
        return names.joined(separator: " / ")
    }
}
