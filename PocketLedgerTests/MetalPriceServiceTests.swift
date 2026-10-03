import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PocketLedger

final class MetalPriceServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_027_000)

    private func response(status: Int = 200, cache: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.gold-api.com/price/XAU/USD")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: cache.map { ["Cache-Control": $0] }
        )!
    }

    private func payload(
        price: String = "4141.799805",
        symbol: String = "XAU",
        currency: String = "USD",
        date: Date? = nil
    ) -> Data {
        let date = ISO8601DateFormatter().string(from: date ?? now.addingTimeInterval(-10))
        return Data("{\"currency\":\"\(currency)\",\"symbol\":\"\(symbol)\",\"price\":\(price),\"updatedAt\":\"\(date)\"}".utf8)
    }

    func testQuoteKeepsDecimalPrecisionAndMarketTimestamp() throws {
        let quote = try MetalPriceService.parse(data: payload(), response: response(), metal: .gold, now: now)
        XCTAssertEqual(quote.usdPricePerTroyOunce, Decimal(string: "4141.799805"))
        XCTAssertEqual(quote.marketDate, now.addingTimeInterval(-10))
        XCTAssertEqual(quote.fetchedAt, now)
        XCTAssertEqual(quote.nextRefreshAt, now.addingTimeInterval(30))
    }

    func testProviderCacheIntervalHasThirtySecondMinimum() throws {
        for (header, expected) in [("public, max-age=120", 120.0), ("max-age=5", 30.0), ("max-age=bad", 30.0)] {
            let quote = try MetalPriceService.parse(data: payload(), response: response(cache: header), metal: .gold, now: now)
            XCTAssertEqual(quote.nextRefreshAt, now.addingTimeInterval(expected))
        }
    }

    func testRejectsMalformedOrInvalidQuotes() {
        for data in [
            Data("not json".utf8), payload(price: "0"), payload(price: "-1"),
            payload(price: "1000000"), payload(price: "null"), payload(symbol: "XAG"),
            payload(currency: "EUR"), payload(date: now.addingTimeInterval(301))
        ] {
            XCTAssertThrowsError(try MetalPriceService.parse(data: data, response: response(), metal: .gold, now: now))
        }
        XCTAssertThrowsError(try MetalPriceService.parse(data: payload(), response: response(status: 429), metal: .gold, now: now))
    }

    func testSilverAndFractionalTimestamp() throws {
        let data = Data("{\"currency\":\"USD\",\"symbol\":\"XAG\",\"price\":48.5,\"updatedAt\":\"2026-10-03T00:00:00.125Z\"}".utf8)
        let quote = try MetalPriceService.parse(data: data, response: response(), metal: .silver, now: now)
        XCTAssertEqual(quote.metal, .silver)
        XCTAssertEqual(quote.usdPricePerTroyOunce, Decimal(string: "48.5"))
    }

    func testPersistentCacheAvoidsNetworkUntilNormalRefreshAndForceRespectsMinimum() async throws {
        let service = MetalPriceService()
        let quote = try MetalPriceService.parse(data: payload(), response: response(cache: "max-age=120"), metal: .gold, now: now)
        let normal = try await service.fetch(metal: .gold, cached: quote, now: now.addingTimeInterval(899))
        XCTAssertEqual(normal, quote)
        let forced = try await service.fetch(metal: .gold, cached: quote, force: true, now: now.addingTimeInterval(119))
        XCTAssertEqual(forced, quote)
    }

    func testFailedRefreshLeavesLastQuoteAvailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMetalPriceProtocol.self]
        let service = MetalPriceService(session: URLSession(configuration: configuration))
        let quote = try MetalPriceService.parse(data: payload(), response: response(), metal: .gold, now: now)
        _ = try await service.fetch(metal: .gold, cached: quote, now: now)
        do {
            _ = try await service.fetch(metal: .gold, force: true, now: now.addingTimeInterval(901))
            XCTFail("Offline refresh must fail instead of replacing the quote with zero.")
        } catch {
            XCTAssertEqual((error as NSError).code, URLError.notConnectedToInternet.rawValue)
        }
        let retained = try await service.fetch(metal: .gold, now: now.addingTimeInterval(10))
        XCTAssertEqual(retained, quote)
    }
}

private final class OfflineMetalPriceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
