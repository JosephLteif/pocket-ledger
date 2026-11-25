import XCTest
@testable import PocketLedger

final class BillScannerParserTests: XCTestCase {
    func testPayableTotalSurvivesMissingItemsAndIgnoresCurrencyEquivalent() {
        let text = """
            SUBTOTAL USD 10.00
            VAT USD 1.10
            TOTAL USD 11.10
            Equivalent LBP 993,450
            """
        let payment = BillScannerParser.payment(in: text)

        XCTAssertEqual(payment.currencies, [.usd])
        XCTAssertEqual(payment.totals, [Money(currency: .usd, minorUnits: 1_110)])
        XCTAssertTrue(BillScannerParser.items(in: text, currency: .usd).isEmpty)
        XCTAssertTrue(BillScannerParser.items(in: text, currency: .lbp).isEmpty)
    }

    func testExplicitTotalsInTwoCurrenciesRemainAvailableForReview() {
        let cases = [
            "TOTAL USD 10.00\nTOTAL LBP 895,000",
            "TOTAL USD 10.00 LBP 895,000",
            "TOTAL 10.00 USD 895,000 LBP"
        ]
        for text in cases {
            let payment = BillScannerParser.payment(in: text)
            XCTAssertEqual(payment.currencies, [.usd, .lbp], text)
            XCTAssertEqual(payment.totals, [
                Money(currency: .usd, minorUnits: 1_000),
                Money(currency: .lbp, minorUnits: 895_000)
            ], text)
        }
    }

    func testUnmarkedPayableTotalUsesCurrencyEvidenceOrOffersAChoice() {
        let marked = BillScannerParser.payment(in: "TOTAL EUR 10.00\nAMOUNT DUE 11.50")
        XCTAssertEqual(marked.totals, [Money(currency: .eur, minorUnits: 1_150)])

        let unmarked = BillScannerParser.payment(in: "TOTAL\n45.000")
        XCTAssertEqual(unmarked.currencies, [.usd, .lbp, .eur])
        XCTAssertTrue(unmarked.hasPrintedTotal)
        XCTAssertTrue(unmarked.totals.contains(Money(currency: .lbp, minorUnits: 45_000)))

        let mixed = BillScannerParser.payment(in: "TOTAL EUR 10.00\nTOTAL USD 11.00\nAMOUNT DUE 12.50")
        XCTAssertEqual(mixed.currencies, [.usd, .eur])
        XCTAssertTrue(mixed.hasPrintedTotal)
        XCTAssertTrue(mixed.totals.isEmpty)
    }

    func testZeroOrNegativePrintedTotalRequiresReview() {
        for line in ["TOTAL USD 0.00", "TOTAL -$10.00", "TOTAL ($10.00)"] {
            let payment = BillScannerParser.payment(in: "Coffee $10.00\n" + line)
            XCTAssertTrue(payment.hasPrintedTotal, line)
            XCTAssertTrue(payment.totals.isEmpty, line)
        }
    }

    func testLebaneseGroupingAndArabicLabels() {
        let text = """
            Rice 2 25,000 50,000
            رز ١٬٢٣٤ ل.ل.
            المجموع الفرعي ٥١٬٢٣٤ ل.ل.
            المبلغ المستحق ٥١.٢٣٤ ل.ل.
            """
        let payment = BillScannerParser.payment(in: text)
        let items = BillScannerParser.items(in: text, currency: payment.currency)

        XCTAssertEqual(payment.totals, [Money(currency: .lbp, minorUnits: 51_234)])
        XCTAssertEqual(items.map(\.name), ["Rice", "رز"])
        XCTAssertEqual(items.map(\.quantity), [2, 1])
        XCTAssertEqual(items.compactMap { $0.total(in: .lbp)?.minorUnits }, [50_000, 1_234])
    }

    func testEuroSeparatorsAreIndependentOfDeviceLocale() {
        let text = "Coffee 1\u{202F}234,50 EUR\nTVA 10% 123,45 EUR\nNet à payer 1.357,95 EUR"
        let payment = BillScannerParser.payment(in: text)

        XCTAssertEqual(payment.totals, [Money(currency: .eur, minorUnits: 135_795)])
        for identifier in ["en_US", "fr_FR", "de_DE", "ar_LB"] {
            let locale = Locale(identifier: identifier)
            let items = BillScannerParser.items(in: text, currency: .eur, locale: locale)
            XCTAssertEqual(items.map(\.name), ["Coffee"])
            XCTAssertEqual(items.first?.total(in: .eur, locale: locale)?.minorUnits, 123_450)
        }
    }

    func testItemNumbersArePreservedAndNegativePricesAreNotMadePositive() {
        let text = "Total Cereal 4.99 USD\nMilk 2L 3.99\nCoffee 15\nPromo -2.00\nCoffee Beans 2 x 4.99 9.98"
        let items = BillScannerParser.items(in: text, currency: .usd)

        XCTAssertEqual(items.map(\.name), ["Total Cereal", "Milk 2L", "Coffee", "Coffee Beans"])
        XCTAssertEqual(items.map(\.quantity), [1, 1, 1, 2])
    }

    func testAIOnlyRecoversRowsBackedByMatchingOCR() {
        let text = "Coffee 10.00\nCoffee 10.00\nBread\n4.50\nMilk\n3.50\nTOTAL 28.00"
        XCTAssertTrue(BillScannerParser.canRecoverWrappedItems(in: text))
        XCTAssertFalse(BillScannerParser.canRecoverWrappedItems(in: "Coffee 10.00\nTOTAL\n10.00"))
        let items = BillScannerParser.items(in: text, currency: .usd, suggestions: [
            .init(name: "Coffee", lineTotal: "99.00"),
            .init(name: "Bread", lineTotal: "4.50"),
            .init(name: "Bread", lineTotal: "4.50"),
            .init(name: "Milk", lineTotal: "35.00"),
            .init(name: "Invented", lineTotal: "10.00")
        ])

        XCTAssertEqual(items.map(\.name), ["Coffee", "Coffee", "Bread"])
        XCTAssertEqual(items.compactMap { $0.total(in: .usd)?.minorUnits }, [1_000, 1_000, 450])
    }

    func testVisionFragmentsJoinByRowIncludingArabicLabelsWithPricesOnTheLeft() {
        let parts = [
            (text: "٥٠٬٠٠٠ ل.ل", bounds: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.025)),
            (text: "المبلغ المستحق", bounds: CGRect(x: 0.4, y: 0.2, width: 0.3, height: 0.025)),
            (text: "٥٠٬٠٠٠", bounds: CGRect(x: 0.1, y: 0.24, width: 0.2, height: 0.02)),
            (text: "رز", bounds: CGRect(x: 0.6, y: 0.245, width: 0.1, height: 0.02))
        ]
        let text = BillScannerParser.orderedText(parts)
        let payment = BillScannerParser.payment(in: text)

        XCTAssertEqual(payment.totals, [Money(currency: .lbp, minorUnits: 50_000)])
        XCTAssertEqual(BillScannerParser.items(in: text, currency: .lbp).first?.name, "رز")
    }
}
