import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import Security

@MainActor
final class LocalWebServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var secureURL: URL?
    @Published private(set) var certificateURL: URL?
    @Published private(set) var certificateFingerprint: String?
    @Published private(set) var errorMessage: String?

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct PairRequest: Decodable {
        let code: String
    }

    private struct TransactionRequest: Decodable {
        struct Split: Decodable {
            let accountID: String
            let amount: String
            let categoryID: String?
        }

        let date: String
        let note: String
        let kind: String
        let splits: [Split]
    }

    private struct Bootstrap: Encodable {
        struct Account: Encodable {
            let id: String
            let name: String
            let currencyCode: String
            let balanceMinorUnits: Int64
        }

        struct Category: Encodable {
            let id: String
            let name: String
        }

        struct Month: Encodable {
            let month: String
            let incomeMinorUnits: Int64
            let expenseMinorUnits: Int64
        }

        struct CategoryExpense: Encodable {
            let categoryID: String?
            let categoryName: String
            let amountMinorUnits: Int64
        }

        struct Metrics: Encodable {
            let totalBalanceMinorUnits: Int64
            let monthIncomeMinorUnits: Int64
            let monthExpenseMinorUnits: Int64
            let monthly: [Month]
            let categoryExpenses: [CategoryExpense]
        }

        struct Transaction: Encodable {
            struct Split: Encodable {
                let amountMinorUnits: Int64
                let currencyCode: String
                let accountName: String
                let categoryName: String?
            }

            let id: String
            let date: String
            let note: String
            let kind: String
            let amountMinorUnits: Int64
            let currencyCode: String
            let categoryName: String?
            let splitCount: Int
            let splits: [Split]
        }

        let currencyCode: String
        let accounts: [Account]
        let categories: [Category]
        let metrics: Metrics
        let transactions: [Transaction]
    }

    private enum RequestFailure: Error {
        case malformed
        case tooLarge
    }

    private let store: LedgerStore
    private let queue = DispatchQueue(label: "com.pocketledger.local-web")
    private var secureListener: NWListener?
    private var certificateListener: NWListener?
    private var generation = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var localAddress: String?
    private var securePort: UInt16?
    private var certificatePort: UInt16?
    private var expectedPairingCode: String?
    private var pairingExpiryTask: Task<Void, Never>?
    private var pairingAttempts = 0
    private var sessionToken: String?
    private var sessionExpiresAt: Date?

    init(store: LedgerStore) {
        self.store = store
    }

    func start() {
        guard !isRunning else { return }
        stop()
        errorMessage = nil

        do {
            guard let address = Self.wifiIPv4Address() else {
                throw LocalWebServerError.wifiUnavailable
            }
            let identity = try LocalWebCertificate.issueServerIdentity(forIPv4Address: address)
            let code = try Self.randomDigits(count: 8)
            let certificateHash = SHA256.hash(data: identity.caCertificateDER)
                .map { String(format: "%02X", $0) }
                .joined(separator: ":")

            guard let tlsIdentity = sec_identity_create(identity.identity) else {
                throw LocalWebServerError.identityConversion
            }
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                tlsIdentity
            )
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv12
            )
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            parameters.requiredInterfaceType = .wifi
            let secureListener = try NWListener(using: parameters)
            secureListener.service = NWListener.Service(
                name: "Pocket Ledger",
                type: "_pocketledger._tcp",
                domain: nil,
                txtRecord: nil
            )

            let certificateParameters = NWParameters.tcp
            certificateParameters.requiredInterfaceType = .wifi
            let certificateListener = try NWListener(using: certificateParameters)

            generation += 1
            let launchID = generation
            localAddress = address
            self.secureListener = secureListener
            self.certificateListener = certificateListener
            expectedPairingCode = code
            pairingCode = code
            let expiry = Date().addingTimeInterval(5 * 60)
            pairingExpiresAt = expiry
            pairingExpiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self, self.expectedPairingCode == code else { return }
                self.expectedPairingCode = nil
                self.pairingCode = nil
            }
            certificateFingerprint = certificateHash
            sessionToken = nil
            sessionExpiresAt = nil
            securePort = nil
            certificatePort = nil
            isRunning = true
            isStarting = true

            secureListener.stateUpdateHandler = { [weak self, weak secureListener] state in
                guard let secureListener else { return }
                Task { @MainActor in
                    self?.listenerChanged(state, listener: secureListener, generation: launchID)
                }
            }
            secureListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection, isSecure: true, generation: launchID)
                }
            }

            certificateListener.stateUpdateHandler = { [weak self, weak certificateListener] state in
                guard let certificateListener else { return }
                Task { @MainActor in
                    self?.listenerChanged(state, listener: certificateListener, generation: launchID)
                }
            }
            certificateListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection, isSecure: false, generation: launchID)
                }
            }

            secureListener.start(queue: queue)
            certificateListener.start(queue: queue)
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        generation += 1
        secureListener?.cancel()
        certificateListener?.cancel()
        secureListener = nil
        certificateListener = nil
        for timeout in connectionTimeouts.values { timeout.cancel() }
        connectionTimeouts.removeAll()
        let openConnections = Array(connections.values)
        connections.removeAll()
        openConnections.forEach { $0.cancel() }
        localAddress = nil
        securePort = nil
        certificatePort = nil
        expectedPairingCode = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingAttempts = 0
        sessionToken = nil
        sessionExpiresAt = nil
        pairingCode = nil
        pairingExpiresAt = nil
        secureURL = nil
        certificateURL = nil
        certificateFingerprint = nil
        isRunning = false
        isStarting = false
    }

    private enum LocalWebServerError: LocalizedError {
        case wifiUnavailable
        case randomGeneration
        case identityConversion

        var errorDescription: String? {
            switch self {
            case .wifiUnavailable:
                return "Connect your iPhone to Wi-Fi, then start PC Access again."
            case .randomGeneration:
                return "Could not create a secure pairing code. Try again."
            case .identityConversion:
                return "Could not prepare the secure PC Access certificate. Try again."
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State, listener: NWListener, generation: Int) {
        guard self.generation == generation else { return }
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            if listener === secureListener {
                securePort = port
                if let localAddress {
                    secureURL = URL(string: "https://\(localAddress):\(port)")
                }
            } else if listener === certificateListener {
                certificatePort = port
                if let localAddress {
                    certificateURL = URL(string: "http://\(localAddress):\(port)/root.cer")
                }
            }
            isStarting = securePort == nil || certificatePort == nil
        case .failed(let error):
            errorMessage = "PC Access could not start: \(error.localizedDescription)"
            stop()
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, isSecure: Bool, generation: Int) {
        guard self.generation == generation, connections.count < 12 else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            Task { @MainActor in self?.connectionClosed(id) }
        }
        connectionTimeouts[id] = Task { [weak connection] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            connection?.cancel()
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, isSecure: isSecure, generation: generation, data: Data())
    }

    private func connectionClosed(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)
        connectionTimeouts.removeValue(forKey: id)?.cancel()
    }

    private func receiveRequest(
        on connection: NWConnection,
        isSecure: Bool,
        generation: Int,
        data: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.generation == generation else {
                    connection.cancel()
                    return
                }
                var accumulated = data
                if let chunk { accumulated.append(chunk) }
                do {
                    if let request = try Self.parseRequest(accumulated) {
                        self.respond(to: request, on: connection, isSecure: isSecure)
                    } else if isComplete || error != nil {
                        self.sendResponse(status: 400, body: Self.jsonError("The request was incomplete."), on: connection)
                    } else {
                        self.receiveRequest(on: connection, isSecure: isSecure, generation: generation, data: accumulated)
                    }
                } catch RequestFailure.tooLarge {
                    self.sendResponse(status: 413, body: Self.jsonError("The request is too large."), on: connection)
                } catch {
                    self.sendResponse(status: 400, body: Self.jsonError("The request was invalid."), on: connection)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection, isSecure: Bool) {
        let id = ObjectIdentifier(connection)
        connectionTimeouts[id]?.cancel()
        guard let localAddress else {
            sendResponse(status: 503, body: Self.jsonError("PC Access is stopping."), on: connection)
            return
        }
        let expectedHost: String?
        if isSecure, let securePort {
            expectedHost = "\(localAddress):\(securePort)"
        } else if !isSecure, let certificatePort {
            expectedHost = "\(localAddress):\(certificatePort)"
        } else {
            expectedHost = nil
        }
        guard request.headers["host"]?.lowercased() == expectedHost?.lowercased() else {
            sendResponse(status: 421, body: Self.jsonError("This address is not available."), on: connection)
            return
        }

        if !isSecure {
            guard request.method == "GET", request.path == "/root.cer" else {
                sendResponse(status: 404, body: Self.jsonError("Not found."), on: connection)
                return
            }
            do {
                let certificate = try LocalWebCertificate.authorityCertificateDER()
                sendResponse(
                    status: 200,
                    body: certificate,
                    contentType: "application/pkix-cert",
                    extraHeaders: ["Content-Disposition": "attachment; filename=PocketLedger-Local-CA.cer"],
                    on: connection
                )
            } catch {
                sendResponse(status: 500, body: Self.jsonError("The certificate could not be read."), on: connection)
            }
            return
        }

        if request.method == "GET" {
            switch request.path {
            case "/", "/index.html":
                serveAsset("index", extension: "html", on: connection)
            case "/app.js":
                serveAsset("app", extension: "js", on: connection)
            case "/styles.css":
                serveAsset("styles", extension: "css", on: connection)
            case "/api/bootstrap":
                guard hasValidSession(request) else {
                    sendResponse(status: 401, body: Self.jsonError("Pair with the current code from your iPhone."), on: connection)
                    return
                }
                sendJSON(makeBootstrap(), on: connection)
            default:
                sendResponse(status: 404, body: Self.jsonError("Not found."), on: connection)
            }
            return
        }

        guard request.method == "POST" else {
            sendResponse(status: 405, body: Self.jsonError("Method not allowed."), on: connection)
            return
        }
        guard let origin = request.headers["origin"],
              let secureURL,
              origin == secureURL.absoluteString else {
            sendResponse(status: 403, body: Self.jsonError("This request did not come from PC Access."), on: connection)
            return
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            sendResponse(status: 415, body: Self.jsonError("Send transaction data as JSON."), on: connection)
            return
        }

        switch request.path {
        case "/api/pair":
            pair(request, on: connection)
        case "/api/transactions":
            guard hasValidSession(request) else {
                sendResponse(status: 401, body: Self.jsonError("Pair with the current code from your iPhone."), on: connection)
                return
            }
            addTransaction(request, on: connection)
        default:
            sendResponse(status: 404, body: Self.jsonError("Not found."), on: connection)
        }
    }

    private func pair(_ request: HTTPRequest, on connection: NWConnection) {
        guard let expectedPairingCode,
              let pairingExpiresAt,
              Date() < pairingExpiresAt,
              pairingAttempts < 10 else {
            self.expectedPairingCode = nil
            self.pairingCode = nil
            sendResponse(status: 401, body: Self.jsonError("The pairing code is incorrect or expired."), on: connection)
            return
        }
        guard let payload = try? JSONDecoder().decode(PairRequest.self, from: request.body) else {
            sendResponse(status: 400, body: Self.jsonError("Enter the pairing code shown on your iPhone."), on: connection)
            return
        }
        pairingAttempts += 1
        guard Self.constantTimeEqual(payload.code, expectedPairingCode) else {
            if pairingAttempts >= 10 {
                self.expectedPairingCode = nil
                self.pairingCode = nil
            }
            sendResponse(status: 401, body: Self.jsonError("The pairing code is incorrect or expired."), on: connection)
            return
        }

        self.expectedPairingCode = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingCode = nil
        guard let token = try? Self.randomToken() else {
            sendResponse(status: 500, body: Self.jsonError("A secure session could not be created."), on: connection)
            return
        }
        sessionToken = token
        sessionExpiresAt = Date().addingTimeInterval(8 * 60 * 60)
        sendResponse(
            status: 204,
            body: Data(),
            extraHeaders: ["Set-Cookie": "__Host-pocketledger=\(token); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=28800"],
            on: connection
        )
    }

    private func hasValidSession(_ request: HTTPRequest) -> Bool {
        guard let sessionToken, let sessionExpiresAt, Date() < sessionExpiresAt,
              let cookie = request.headers["cookie"]?.split(separator: ";").map(String.init)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("__Host-pocketledger=") }),
              let value = cookie.split(separator: "=", maxSplits: 1).last else {
            return false
        }
        return Self.constantTimeEqual(String(value), sessionToken)
    }

    private func addTransaction(_ request: HTTPRequest, on connection: NWConnection) {
        guard let payload = try? JSONDecoder().decode(TransactionRequest.self, from: request.body),
              let kind = TransactionKind(rawValue: payload.kind),
              kind == .expense || kind == .income,
              payload.note.count <= 200,
              !payload.splits.isEmpty,
              payload.splits.count <= 50,
              let date = Self.parseDate(payload.date) else {
            sendResponse(status: 400, body: Self.jsonError("Check the transaction details and try again."), on: connection)
            return
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: store.activeAccounts.map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: store.data.categories.filter { !$0.isArchived }.map { ($0.id, $0) })
        var movements: [MoneyMovement] = []
        var selectedCurrency: LedgerCurrency?
        for split in payload.splits {
            guard let accountID = UUID(uuidString: split.accountID),
                  let account = accountsByID[accountID] else {
                sendResponse(status: 422, body: Self.jsonError("Choose an active account for each split."), on: connection)
                return
            }
            guard selectedCurrency == nil || selectedCurrency == account.currency else {
                sendResponse(status: 422, body: Self.jsonError("All splits in one transaction must use the same currency."), on: connection)
                return
            }
            guard let money = Self.parsePositiveMoney(split.amount, currency: account.currency) else {
                sendResponse(
                    status: 422,
                    body: Self.jsonError("Enter a positive amount for each split."),
                    on: connection
                )
                return
            }
            if let categoryID = split.categoryID {
                guard let id = UUID(uuidString: categoryID), categoriesByID[id] != nil else {
                    sendResponse(status: 422, body: Self.jsonError("Choose an active category for each split."), on: connection)
                    return
                }
                movements.append(MoneyMovement(accountID: account.id, money: money, categoryID: id))
            } else {
                movements.append(MoneyMovement(accountID: account.id, money: money))
            }
            selectedCurrency = account.currency
        }

        let transaction = LedgerTransaction(
            date: date,
            note: payload.note.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            categoryID: nil,
            outflows: kind == .expense ? movements : [],
            inflows: kind == .income ? movements : []
        )
        guard store.addTransaction(transaction) else {
            sendResponse(status: 422, body: Self.jsonError(store.lastActionStatus ?? "The transaction could not be saved."), on: connection)
            return
        }
        sendResponse(status: 201, body: Data(), contentType: "application/json", on: connection)
    }

    private func makeBootstrap() -> Data {
        let calendar = Calendar.current
        let now = Date()
        let activeAccounts = store.activeAccounts
        let currency = activeAccounts.first(where: \.includeInTotals)?.currency
            ?? activeAccounts.first?.currency
            ?? .usd
        let currentInterval = calendar.dateInterval(of: .month, for: now)
            ?? DateInterval(start: now, duration: 0)
        let currentSnapshot = MetricsSnapshot.make(
            index: store.ledgerIndex,
            interval: currentInterval,
            selectedCurrency: currency,
            selectedCategoryID: nil
        )
        let months = (-5...0).compactMap { offset -> Bootstrap.Month? in
            guard let date = calendar.date(byAdding: .month, value: offset, to: now),
                  let interval = calendar.dateInterval(of: .month, for: date) else {
                return nil
            }
            let snapshot = MetricsSnapshot.make(
                index: store.ledgerIndex,
                interval: interval,
                selectedCurrency: currency,
                selectedCategoryID: nil
            )
            let month = DateFormatter()
            month.calendar = Calendar(identifier: .gregorian)
            month.locale = Locale(identifier: "en_US_POSIX")
            month.dateFormat = "yyyy-MM"
            return Bootstrap.Month(
                month: month.string(from: interval.start),
                incomeMinorUnits: snapshot.income,
                expenseMinorUnits: snapshot.expenses
            )
        }
        let transactions = store.recentTransactions.prefix(100).map { transaction in
            let movementCurrencies = (transaction.outflows + transaction.inflows).map { $0.money.currency }
            let transactionCurrency = movementCurrencies.contains(currency) ? currency : movementCurrencies.first ?? currency
            let amountMovements: [MoneyMovement]
            switch transaction.kind {
            case .expense:
                amountMovements = transaction.outflows
            case .income:
                amountMovements = transaction.inflows
            case .transfer:
                amountMovements = transaction.outflows
            }
            let amount = amountMovements.reduce(Int64.zero) { total, movement in
                total + (financeConvertedMinorUnits(
                    movement.money,
                    to: transactionCurrency,
                    using: transaction.exchangeRate
                ) ?? 0)
            }
            let categoryIDs = Set((transaction.outflows + transaction.inflows)
                .compactMap { transaction.categoryID(for: $0) })
            let categoryNames = categoryIDs.map { store.categoryPath(for: $0) }.sorted()
            let splitMovements = transaction.kind == .transfer
                ? transaction.outflows + transaction.inflows
                : amountMovements
            return Bootstrap.Transaction(
                id: transaction.id.uuidString,
                date: Self.iso8601String(transaction.date),
                note: transaction.note,
                kind: transaction.kind.rawValue,
                amountMinorUnits: amount,
                currencyCode: transactionCurrency.rawValue,
                categoryName: transaction.kind == .transfer
                    ? nil
                    : categoryNames.isEmpty ? nil : categoryNames.count == 1 ? categoryNames[0] : "Multiple categories",
                splitCount: max(transaction.outflows.count, transaction.inflows.count),
                splits: splitMovements.map { movement in
                    let categoryID = transaction.categoryID(for: movement)
                    return Bootstrap.Transaction.Split(
                        amountMinorUnits: movement.money.minorUnits,
                        currencyCode: movement.money.currency.rawValue,
                        accountName: store.data.accounts.first { $0.id == movement.accountID }?.name ?? "Unknown account",
                        categoryName: categoryID.map { store.categoryPath(for: $0) }
                    )
                }
            )
        }
        let result = Bootstrap(
            currencyCode: currency.rawValue,
            accounts: activeAccounts.map {
                Bootstrap.Account(
                    id: $0.id.uuidString,
                    name: $0.name,
                    currencyCode: $0.currency.rawValue,
                    balanceMinorUnits: store.balance(for: $0).minorUnits
                )
            },
            categories: store.activeCategories.map {
                Bootstrap.Category(id: $0.id.uuidString, name: store.categoryPath(for: $0.id))
            },
            metrics: Bootstrap.Metrics(
                totalBalanceMinorUnits: store.ledgerIndex.availableBalance(for: currency).minorUnits,
                monthIncomeMinorUnits: currentSnapshot.income,
                monthExpenseMinorUnits: currentSnapshot.expenses,
                monthly: months,
                categoryExpenses: currentSnapshot.categories.map {
                    Bootstrap.CategoryExpense(
                        categoryID: $0.categoryID?.uuidString,
                        categoryName: $0.title,
                        amountMinorUnits: $0.amount
                    )
                }
            ),
            transactions: transactions
        )
        return (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
    }

    private func serveAsset(_ name: String, extension fileExtension: String, on connection: NWConnection) {
        let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "LocalWeb")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
        guard let url, let data = try? Data(contentsOf: url) else {
            sendResponse(status: 404, body: Self.jsonError("The PC Access page could not be loaded."), on: connection)
            return
        }
        let contentType: String
        switch fileExtension {
        case "html": contentType = "text/html; charset=utf-8"
        case "js": contentType = "text/javascript; charset=utf-8"
        default: contentType = "text/css; charset=utf-8"
        }
        sendResponse(status: 200, body: data, contentType: contentType, on: connection, useWebPolicy: true)
    }

    private func sendJSON(_ data: Data, on connection: NWConnection) {
        sendResponse(status: 200, body: data, contentType: "application/json; charset=utf-8", on: connection)
    }

    private func sendResponse(
        status: Int,
        body: Data,
        contentType: String = "application/json; charset=utf-8",
        extraHeaders: [String: String] = [:],
        on connection: NWConnection,
        useWebPolicy: Bool = false
    ) {
        connectionTimeouts[ObjectIdentifier(connection)]?.cancel()
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 421: reason = "Misdirected Request"
        case 422: reason = "Unprocessable Content"
        default: reason = "Internal Server Error"
        }
        var headers = [
            "Content-Type": contentType,
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
            "Connection": "close",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "X-Frame-Options": "DENY"
        ]
        if useWebPolicy {
            headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
            headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        }
        headers.merge(extraHeaders) { _, new in new }
        let headerText = (["HTTP/1.1 \(status) \(reason)"] + headers.map { "\($0.key): \($0.value)" })
            .joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(headerText.utf8)
        response.append(body)
        connection.send(
            content: response,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak connection] _ in connection?.cancel() }
        )
    }

    private static func parseRequest(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 80_000 else { throw RequestFailure.tooLarge }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw RequestFailure.tooLarge }
            return nil
        }
        guard separator.lowerBound <= 16_384,
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw RequestFailure.malformed
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw RequestFailure.malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1" else { throw RequestFailure.malformed }
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RequestFailure.malformed }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { throw RequestFailure.malformed }
            headers[key] = value
        }
        guard headers["host"] != nil else { throw RequestFailure.malformed }
        guard headers["transfer-encoding"] == nil else { throw RequestFailure.malformed }
        guard let rawLength = headers["content-length"] else {
            if ["GET", "HEAD"].contains(String(parts[0])) {
                guard data.count == separator.upperBound else { throw RequestFailure.malformed }
                return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: Data())
            }
            throw RequestFailure.malformed
        }
        guard let contentLength = Int(rawLength), contentLength >= 0 else { throw RequestFailure.malformed }
        guard contentLength <= 64_000 else { throw RequestFailure.tooLarge }
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        guard data.count == bodyStart + contentLength else { throw RequestFailure.malformed }
        return HTTPRequest(
            method: String(parts[0]),
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private static func jsonError(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data("{}".utf8)
    }

    private static func randomDigits(count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalWebServerError.randomGeneration
        }
        let value = bytes.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) } % 100_000_000
        return String(format: "%0*llu", count, value)
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalWebServerError.randomGeneration
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parsePositiveMoney(_ value: String, currency: LedgerCurrency) -> Money? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { (48...57).contains($0.value) } }),
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        let scaled = decimal * Decimal(currency.minorUnitScale)
        var rounded = Decimal()
        var valueToRound = scaled
        NSDecimalRound(&rounded, &valueToRound, 0, .plain)
        guard scaled == rounded, rounded > 0,
              NSDecimalNumber(decimal: rounded).compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else {
            return nil
        }
        return Money(currency: currency, minorUnits: NSDecimalNumber(decimal: rounded).int64Value)
    }

    private static func wifiIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let interface = entry.pointee
            if String(cString: interface.ifa_name) == "en0",
               let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if let text = inet_ntoa(ipv4) { return String(cString: text) }
            }
            current = interface.ifa_next
        }
        return nil
    }
}
