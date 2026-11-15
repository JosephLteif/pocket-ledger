import XCTest
@testable import PocketLedger

final class CategoryPickerTests: XCTestCase {
    func testBreadcrumbListsAncestorsWithoutRepeatingSearchResult() {
        let home = LedgerCategory(name: "Home")
        let groceries = LedgerCategory(name: "Groceries", parentID: home.id)
        let market = LedgerCategory(name: "Market", parentID: groceries.id)
        let categoriesByID = Dictionary(
            [home, groceries, market].map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(
            CategoryPickerSection.breadcrumb(for: market, categoriesByID: categoriesByID),
            "\(home.displayName) › \(groceries.displayName)"
        )
    }

    func testBreadcrumbStopsAtMissingParentsAndCycles() {
        let missingParentCategory = LedgerCategory(name: "Orphan", parentID: UUID())
        XCTAssertNil(
            CategoryPickerSection.breadcrumb(
                for: missingParentCategory,
                categoriesByID: [missingParentCategory.id: missingParentCategory]
            )
        )

        let firstID = UUID()
        let secondID = UUID()
        let first = LedgerCategory(id: firstID, name: "First", parentID: secondID)
        let second = LedgerCategory(id: secondID, name: "Second", parentID: firstID)
        let categoriesByID = [first.id: first, second.id: second]

        XCTAssertEqual(
            CategoryPickerSection.breadcrumb(for: first, categoriesByID: categoriesByID),
            second.displayName
        )
    }
}
