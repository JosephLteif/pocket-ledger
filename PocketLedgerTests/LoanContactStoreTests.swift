import XCTest
@testable import PocketLedger

final class LoanContactStoreTests: XCTestCase {
    func testRenamingLoanContactUpdatesLinkedLoansAndPreservesLoanHistory() throws {
        let fixture = makeFixture()
        let renamed = try LoanContactDataOperation.updating(
            LoanContact(id: fixture.contact.id, name: "  New Name\n"),
            in: fixture.data
        )

        var expectedLinkedLoan = fixture.linkedLoan
        expectedLinkedLoan.counterparty = "New Name"
        XCTAssertEqual(renamed.loanContacts, [LoanContact(id: fixture.contact.id, name: "New Name")])
        XCTAssertEqual(renamed.loans, [expectedLinkedLoan, fixture.legacyLoan])
        XCTAssertEqual(renamed.transactions, fixture.data.transactions)
    }

    func testDeletingLoanContactUnlinksLoansAndPreservesNamesAndHistory() throws {
        let fixture = makeFixture()
        let deleted = try LoanContactDataOperation.deleting(id: fixture.contact.id, from: fixture.data)

        var expectedLinkedLoan = fixture.linkedLoan
        expectedLinkedLoan.counterpartyContactID = nil
        XCTAssertTrue(deleted.loanContacts.isEmpty)
        XCTAssertEqual(deleted.loans, [expectedLinkedLoan, fixture.legacyLoan])
        XCTAssertEqual(deleted.transactions, fixture.data.transactions)
    }

    func testLoanContactNamesAreTrimmedAndBlankOrDuplicateNamesAreRejected() throws {
        let existing = LoanContact(name: "Existing")
        let other = LoanContact(name: "Other")
        let data = FinanceData(
            accounts: [], categories: [], transactions: [], loanContacts: [existing, other]
        )

        let added = try LoanContactDataOperation.adding(LoanContact(name: "  New name  "), to: data)
        XCTAssertEqual(added.loanContacts.last?.name, "New name")

        XCTAssertThrowsError(
            try LoanContactDataOperation.adding(LoanContact(name: " \n "), to: data)
        ) { error in
            XCTAssertEqual(error as? LoanContactMutationError, .invalidName)
        }
        XCTAssertThrowsError(
            try LoanContactDataOperation.adding(LoanContact(name: "  EXISTING "), to: data)
        ) { error in
            XCTAssertEqual(error as? LoanContactMutationError, .duplicateName)
        }
        XCTAssertThrowsError(
            try LoanContactDataOperation.updating(
                LoanContact(id: existing.id, name: " other "),
                in: data
            )
        ) { error in
            XCTAssertEqual(error as? LoanContactMutationError, .duplicateName)
        }
    }

    private func makeFixture() -> (
        data: FinanceData,
        contact: LoanContact,
        linkedLoan: Loan,
        legacyLoan: Loan
    ) {
        let contact = LoanContact(name: "Old Name")
        let principal = Money(currency: .usd, minorUnits: 10_000)
        let payment = LoanPayment(
            date: Date(timeIntervalSince1970: 1_700_000_100),
            amount: Money(currency: .usd, minorUnits: 2_000),
            transactionID: UUID()
        )
        let linkedLoan = Loan(
            counterparty: contact.name,
            counterpartyContactID: contact.id,
            direction: .lent,
            currency: .usd,
            startingAmount: principal,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payments: [payment]
        )
        let funding = LedgerTransaction(
            note: "Loan funded",
            kind: .transfer,
            categoryID: nil,
            outflows: [],
            inflows: [],
            loanID: linkedLoan.id,
            loanActivity: .funding,
            loanPrincipalAmount: principal
        )
        let paymentTransaction = LedgerTransaction(
            id: payment.transactionID,
            note: "Loan payment",
            kind: .transfer,
            categoryID: nil,
            outflows: [],
            inflows: [],
            loanID: linkedLoan.id,
            loanPaymentID: payment.id,
            loanActivity: .payment,
            loanPrincipalAmount: payment.amount
        )
        let legacyLoan = Loan(
            counterparty: contact.name,
            direction: .borrowed,
            currency: .usd,
            startingAmount: Money(currency: .usd, minorUnits: 5_000)
        )
        let transactions = [funding, paymentTransaction]
        return (
            FinanceData(
                accounts: [],
                categories: [],
                transactions: transactions,
                loans: [linkedLoan, legacyLoan],
                loanContacts: [contact]
            ),
            contact,
            linkedLoan,
            legacyLoan
        )
    }
}
