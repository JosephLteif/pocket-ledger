#if DEBUG
import Foundation

enum DesignReviewFixture {
    static func make() -> FinanceData {
        if ProcessInfo.processInfo.arguments.contains("-DesignReviewEmpty") {
            return FinanceData(accounts: [], categories: [], transactions: [])
        }
        let usesLongNames = ProcessInfo.processInfo.arguments.contains("-DesignReviewLongNames")
        let checking = Account(
            name: usesLongNames ? "Everyday Checking for household expenses and recurring payments" : "Everyday Checking",
            type: .bankAccount,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 462_000)
        )
        let savings = Account(
            name: "Rainy Day Savings",
            type: .bankAccount,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 240_000)
        )
        let cash = Account(
            name: "Cash Wallet",
            type: .cash,
            currency: .lbp,
            openingBalance: Money(currency: .lbp, minorUnits: 1_500_000)
        )
        let gold = Account(
            name: "Gold holdings",
            type: .physicalAsset,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0),
            tracking: AccountTracking(physicalAssetSubtype: .gold)
        )
        let brokerage = Account(
            name: "Brokerage",
            type: .investment,
            currency: .usd,
            openingBalance: Money(currency: .usd, minorUnits: 0)
        )
        let groceries = LedgerCategory(name: "Groceries", systemImage: "basket.fill")
        let dining = LedgerCategory(name: "Dining", systemImage: "fork.knife")
        let home = LedgerCategory(name: "Home", systemImage: "house.fill")
        let income = LedgerCategory(name: "Salary", systemImage: "briefcase.fill")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let date = { (daysAgo: Int) in
            calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        }

        let transactions = [
            LedgerTransaction(
                date: date(3),
                note: "Monthly salary",
                kind: .income,
                categoryID: income.id,
                outflows: [],
                inflows: [MoneyMovement(
                    accountID: checking.id,
                    money: Money(currency: .usd, minorUnits: 320_000)
                )]
            ),
            LedgerTransaction(
                date: date(2),
                note: "Weekly groceries",
                kind: .expense,
                categoryID: groceries.id,
                outflows: [MoneyMovement(
                    accountID: checking.id,
                    money: Money(currency: .usd, minorUnits: 8_470)
                )],
                inflows: []
            ),
            LedgerTransaction(
                date: date(1),
                note: "Coffee shop",
                kind: .expense,
                categoryID: dining.id,
                outflows: [MoneyMovement(
                    accountID: checking.id,
                    money: Money(currency: .usd, minorUnits: 650)
                )],
                inflows: []
            ),
            LedgerTransaction(
                date: date(4),
                note: "Electricity bill",
                kind: .expense,
                categoryID: home.id,
                outflows: [MoneyMovement(
                    accountID: checking.id,
                    money: Money(currency: .usd, minorUnits: 9_620)
                )],
                inflows: []
            ),
            LedgerTransaction(
                date: date(5),
                note: "Savings transfer",
                kind: .transfer,
                categoryID: nil,
                outflows: [MoneyMovement(
                    accountID: checking.id,
                    money: Money(currency: .usd, minorUnits: 45_000)
                )],
                inflows: [MoneyMovement(
                    accountID: savings.id,
                    money: Money(currency: .usd, minorUnits: 45_000)
                )]
            ),
            LedgerTransaction(
                date: date(6),
                note: "Taxi ride",
                kind: .expense,
                categoryID: dining.id,
                outflows: [MoneyMovement(
                    accountID: cash.id,
                    money: Money(currency: .lbp, minorUnits: 185_000)
                )],
                inflows: []
            )
        ]
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let loanID = UUID()
        let loanFundingID = UUID()
        let loanAmount = Money(currency: .usd, minorUnits: 45_000)
        let loan = Loan(
            id: loanID,
            counterparty: "Alex Morgan",
            direction: .lent,
            currency: .usd,
            startingAmount: loanAmount,
            startedAt: date(15),
            dueDate: nextWeek,
            settlementAccountID: checking.id,
            fundingTransactionID: loanFundingID
        )
        let loanFunding = LedgerTransaction(
            id: loanFundingID,
            date: date(15),
            note: "Loan to Alex Morgan",
            kind: .transfer,
            categoryID: nil,
            outflows: [MoneyMovement(accountID: checking.id, money: loanAmount)],
            inflows: [],
            loanID: loanID,
            loanActivity: .funding,
            loanPrincipalAmount: loanAmount
        )

        return FinanceData(
            accounts: [checking, savings, cash, gold, brokerage],
            categories: [groceries, dining, home, income],
            transactions: transactions + [loanFunding],
            loans: [loan],
            scheduledTransactions: [ScheduledTransaction(
                nextRunDate: nextWeek,
                frequency: .monthly,
                note: "Streaming subscription",
                kind: .expense,
                categoryID: home.id,
                outflows: [MoneyMovement(
                    accountID: checking.id,
                    money: Money(currency: .usd, minorUnits: 1_599)
                )],
                inflows: []
            )],
            exchangeRates: [ExchangeRate(
                baseCurrency: .usd,
                quoteCurrency: .lbp,
                quoteUnitsPerBaseUnit: Decimal(89_500)
            )],
            budgets: [LedgerBudget(
                categoryID: groceries.id,
                currency: .usd,
                monthlyLimit: Money(currency: .usd, minorUnits: 50_000),
                startedAt: calendar.dateInterval(of: .month, for: today)?.start
            )],
            savingsGoals: [SavingsGoal(
                name: "Emergency fund",
                targetAmount: Money(currency: .usd, minorUnits: 1_000_000),
                currentAmount: Money(currency: .usd, minorUnits: 325_000),
                targetDate: calendar.date(byAdding: .month, value: 1, to: today) ?? today
            )],
            templates: [LedgerTemplate(name: "Weekly groceries", transaction: transactions[1])]
        )
    }
}
#endif
