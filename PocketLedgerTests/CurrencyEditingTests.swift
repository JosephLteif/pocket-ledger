import XCTest
@testable import PocketLedger

final class CurrencyEditingTests: XCTestCase {
    func testFormattingWhileTypingPreservesPartialDecimals() {
        let locale = Locale(identifier: "en_US")
        for (input, expected) in [("", ""), ("-", "-"), ("1234", "1,234"),
                                  ("1234.", "1,234."), ("1234.00", "1,234.00"),
                                  ("-1234.5", "-1,234.5"), ("1,234.5", "1,234.5")] {
            XCTAssertEqual(LedgerCurrency.usd.formattedEditingInput(input, locale: locale), expected)
        }
    }

    func testFormattingWhileTypingUsesLocaleSeparators() {
        let locale = Locale(identifier: "de_DE")
        let formatted = LedgerCurrency.eur.formattedEditingInput("1234,50", locale: locale)
        XCTAssertEqual(formatted, "1.234,50")
        XCTAssertEqual(Money.parse(formatted, currency: .eur, locale: locale)?.minorUnits, 123450)
        XCTAssertEqual(LedgerCurrency.lbp.formattedEditingInput("1234567", locale: Locale(identifier: "en_US")), "1,234,567")
    }
}
