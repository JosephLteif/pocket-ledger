import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only metal symbols are sent to Gold API; holdings and account data stay on device.
actor MetalPriceService {
    static let shared = MetalPriceService()

    enum QuoteError: LocalizedError {
        case invalidResponse
        case serverStatus(Int)
        case invalidQuote

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The price provider returned an invalid response."
            case .serverStatus: "The price provider is unavailable. Try again later or enter a manual price."
            case .invalidQuote: "The price provider returned an unusable quote."
            }
        }
    }

    private let session: URLSession
    private var quotes: [String: MetalQuote] = [:]
    private var requests: [String: Task<MetalQuote, Error>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(
        metal: PreciousMetal,
        cached: MetalQuote? = nil,
        force: Bool = false,
        now: Date = .now
    ) async throws -> MetalQuote {
        let symbol = metal.apiSymbol
        let savedQuotes: [MetalQuote] = [quotes[symbol], cached].compactMap { $0 }
        let usableQuotes = savedQuotes.filter { quote in
            guard quote.metal == metal, !quote.usdPricePerTroyOunce.isNaN,
                  quote.usdPricePerTroyOunce > Decimal.zero,
                  quote.usdPricePerTroyOunce < Decimal(1_000_000) else { return false }
            return quote.fetchedAt <= now.addingTimeInterval(300)
        }
        let candidate = usableQuotes.max { $0.fetchedAt < $1.fetchedAt }
        if let candidate,
           now < candidate.nextRefreshAt || (!force && now.timeIntervalSince(candidate.fetchedAt) < 900) {
            quotes[symbol] = candidate
            return candidate
        }
        if let request = requests[symbol] {
            return try await request.value
        }

        let session = session
        let task = Task<MetalQuote, Error> {
            var request = URLRequest(url: URL(string: "https://api.gold-api.com/price/\(symbol)/USD")!)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw QuoteError.invalidResponse
            }
            return try Self.parse(data: data, response: response, metal: metal, now: now)
        }
        requests[symbol] = task
        defer { requests[symbol] = nil }
        let quote = try await task.value
        quotes[symbol] = quote
        return quote
    }

    nonisolated static func parse(
        data: Data,
        response: HTTPURLResponse,
        metal: PreciousMetal,
        now: Date
    ) throws -> MetalQuote {
        guard (200..<300).contains(response.statusCode) else {
            throw QuoteError.serverStatus(response.statusCode)
        }
        struct Payload: Decodable {
            let currency: String
            let symbol: String
            let price: Decimal
            let updatedAt: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.currency == "USD", payload.symbol == metal.apiSymbol,
              !payload.price.isNaN, payload.price > 0, payload.price < 1_000_000 else {
            throw QuoteError.invalidQuote
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var marketDate = formatter.date(from: payload.updatedAt)
        if marketDate == nil {
            formatter.formatOptions = [.withInternetDateTime]
            marketDate = formatter.date(from: payload.updatedAt)
        }
        guard let marketDate, marketDate <= now.addingTimeInterval(300),
              marketDate.timeIntervalSince1970 > 0 else {
            throw QuoteError.invalidQuote
        }
        let cacheSeconds = response.value(forHTTPHeaderField: "Cache-Control")?
            .split(separator: ",")
            .compactMap { directive -> TimeInterval? in
                let parts = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "max-age" else { return nil }
                return TimeInterval(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
            }.first
        let minimumRefreshInterval = max(30, cacheSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 30)
        // Gold API's XAU/XAG USD spot quote is interpreted as USD per troy ounce.
        return MetalQuote(
            metal: metal,
            usdPricePerTroyOunce: payload.price,
            marketDate: marketDate,
            fetchedAt: now,
            nextRefreshAt: now.addingTimeInterval(minimumRefreshInterval)
        )
    }
}
