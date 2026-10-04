import Charts
import Foundation
import SwiftUI

private enum MetricsPeriod: String, CaseIterable, Identifiable {
    case month = "Month"
    case year = "Year"
    case custom = "Custom"

    var id: String { rawValue }
}

private enum MetricsBreakdown: String, CaseIterable, Identifiable {
    case category = "Category"
    case account = "Account"

    var id: String { rawValue }
}

private typealias CategoryMetric = MetricsCategorySnapshot

private struct CategoryMonthPoint: Identifiable {
    let date: Date
    let amount: Int64

    var id: Date { date }
}

private struct MetricsReportShareItem: Identifiable {
    let url: URL

    var id: URL { url }
}

private struct CategoryMetricsDetailSnapshot {
    let monthlyPoints: [CategoryMonthPoint]
    let selectedMonthTransactions: [LedgerTransaction]
    let selectedMonthTotal: Int64
    let subcategories: [CategoryMetric]

    static var empty: CategoryMetricsDetailSnapshot {
        CategoryMetricsDetailSnapshot(
            monthlyPoints: [],
            selectedMonthTransactions: [],
            selectedMonthTotal: 0,
            subcategories: []
        )
    }

    @MainActor
    static func make(
        index: LedgerIndex,
        categoryID: UUID?,
        currency: LedgerCurrency,
        anchorDate: Date,
        selectedInterval: DateInterval,
        calendar: Calendar = .current
    ) -> CategoryMetricsDetailSnapshot {
        let currentMonth = calendar.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate
        let monthStarts = (0..<7).compactMap {
            calendar.date(byAdding: .month, value: $0 - 6, to: currentMonth)
                .flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
        }.filter {
            ProEntitlementStore.shared.hasProAccess
                || PocketLedgerTierPolicy.canViewHistoricalPeriod(
                    start: $0,
                    isCalendarYear: false,
                    calendar: calendar
                )
        }
        guard let firstMonth = monthStarts.first,
              let lastMonth = monthStarts.last,
              let lastInterval = calendar.dateInterval(of: .month, for: lastMonth) else {
            return .empty
        }

        let range = DateInterval(start: firstMonth, end: lastInterval.end)
        var monthlyAmounts = monthStarts.reduce(into: [Date: Int64]()) { result, month in
            result[month] = 0
        }
        var selectedMonthTransactions: [LedgerTransaction] = []
        var selectedMonthTotal: Int64 = 0

        for transaction in index.sortedTransactions {
            guard transaction.kind == .expense,
                  range.contains(transaction.date),
                  index.categoryMatches(
                      transaction.categoryID,
                      selectedCategoryID: categoryID
                  ),
                  index.categoryIncludedInTotals(transaction.categoryID),
                  transaction.outflows.contains(where: {
                      index.includesInTotals(accountID: $0.accountID)
                          && financeConvertedMinorUnits(
                              $0.money,
                              to: currency,
                              using: transaction.exchangeRate
                          ) != nil
                  }),
                  let monthStart = calendar.dateInterval(of: .month, for: transaction.date)?.start else {
                continue
            }

            let outflowAmount = transaction.outflows.reduce(Int64.zero) { total, movement in
                guard index.includesInTotals(accountID: movement.accountID),
                      let converted = financeConvertedMinorUnits(
                          movement.money,
                          to: currency,
                          using: transaction.exchangeRate
                      ) else {
                    return total
                }
                return total + converted
            }
            monthlyAmounts[monthStart, default: 0] += outflowAmount

            if monthStart == currentMonth {
                selectedMonthTransactions.append(transaction)
                selectedMonthTotal += outflowAmount
            }
        }

        return CategoryMetricsDetailSnapshot(
            monthlyPoints: monthStarts.map {
                CategoryMonthPoint(date: $0, amount: monthlyAmounts[$0] ?? 0)
            },
            selectedMonthTransactions: selectedMonthTransactions,
            selectedMonthTotal: selectedMonthTotal,
            subcategories: MetricsSnapshot.subcategoryBreakdown(
                index: index,
                categoryID: categoryID,
                interval: selectedInterval,
                selectedCurrency: currency
            )
        )
    }
}

@MainActor
struct MetricsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @ObservedObject private var proAccess = ProEntitlementStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var period: MetricsPeriod = .month
    @State private var selectedCurrency: LedgerCurrency = .usd
    @State private var anchorDate = Date.now
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date.now) ?? Date.now
    @State private var customEnd = Date.now
    @State private var selectedCategoryID: UUID?
    @State private var breakdown: MetricsBreakdown = .category
    @State private var isShowingBreakdownFilters = false
    @State private var isExportOptionsPresented = false
    @State private var reportToShare: MetricsReportShareItem?
    @State private var reportError: String?
    @State private var snapshot = MetricsSnapshot.empty

    private var interval: DateInterval {
        let calendar = Calendar.current

        switch period {
        case .month:
            return calendar.dateInterval(of: .month, for: anchorDate)
                ?? DateInterval(start: anchorDate, duration: 31 * 24 * 60 * 60)
        case .year:
            return calendar.dateInterval(of: .year, for: anchorDate)
                ?? DateInterval(start: anchorDate, duration: 365 * 24 * 60 * 60)
        case .custom:
            let start = calendar.startOfDay(for: customStart)
            let endOfSelectedDay = calendar.startOfDay(for: customEnd)
            let end = endOfSelectedDay > start
                ? calendar.date(byAdding: .day, value: 1, to: endOfSelectedDay) ?? endOfSelectedDay
                : calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                PocketGlassContainer(spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        screenSubtitle
                        periodControls
                        periodNavigator
                        totalsHeader(snapshot)
                        spendingChart(snapshot)
                        categoryRows(snapshot)
                        activityMix(snapshot)
                    }
                    .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .pocketScreen()
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                PocketLedgerToolbar(security: security) {
                    ToolbarItem(placement: .primaryAction) {
                        if proAccess.hasProAccess {
                            Button {
                                isExportOptionsPresented = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share metrics PDF report")
                            .accessibilityHint("Creates a shareable PDF report")
                        } else {
                            ProUpgradeButton(feature: .pdfReports) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Unlock PDF reports with Pro")
                        }
                    }
                }
            }
            .onAppear(perform: refreshSnapshot)
            .onChange(of: period) { _, _ in refreshSnapshot() }
            .onChange(of: selectedCurrency) { _, _ in refreshSnapshot() }
            .onChange(of: anchorDate) { _, _ in refreshSnapshot() }
            .onChange(of: customStart) { _, _ in refreshSnapshot() }
            .onChange(of: customEnd) { _, _ in refreshSnapshot() }
            .onChange(of: selectedCategoryID) { _, _ in refreshSnapshot() }
            .onChange(of: store.ledgerRevision) { _, _ in refreshSnapshot() }
            .onChange(of: proAccess.hasProAccess) { _, hasProAccess in
                guard !hasProAccess else { return }
                if period == .custom {
                    period = .month
                }
                if !canViewSelectedPeriodAsFree {
                    anchorDate = .now
                }
            }
            .sheet(item: $reportToShare) { report in
                MetricsReportShareSheet(url: report.url)
            }
            .confirmationDialog(
                "Export Metrics PDF",
                isPresented: $isExportOptionsPresented,
                titleVisibility: .visible
            ) {
                Button("All \(snapshot.filteredTransactions.count) transactions") {
                    generateReport(transactionLimit: nil)
                }
                if snapshot.filteredTransactions.count > 500 {
                    Button("Latest 500 transactions") {
                        generateReport(transactionLimit: 500)
                    }
                }
                if snapshot.filteredTransactions.count > 100 {
                    Button("Latest 100 transactions") {
                        generateReport(transactionLimit: 100)
                    }
                }
                Button("Summary only") {
                    generateReport(transactionLimit: 0)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The report uses the current period and filters. Transaction details are listed newest first.")
            }
            .alert("Report not created", isPresented: reportErrorPresented) {
                Button("OK") { reportError = nil }
            } message: {
                Text(reportError ?? "")
            }
        }
    }

    private var screenSubtitle: some View {
        Text("See how your money moves")
            .font(.subheadline)
            .foregroundStyle(PocketLedgerTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
    }

    private var periodControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("Period", selection: $period) {
                    ForEach(MetricsPeriod.allCases.filter { proAccess.hasProAccess || $0 != .custom }) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("metrics-period-picker")

                Picker("Currency", selection: $selectedCurrency) {
                    ForEach(LedgerCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                .pickerStyle(.menu)
                .tint(PocketLedgerTheme.textPrimary)
                .padding(.horizontal, 8)
                .pocketGlassSurface(cornerRadius: 10, tint: PocketLedgerTheme.surfaceElevated.opacity(0.22))
            }

            if !proAccess.hasProAccess {
                ProUpgradeButton(feature: .historicalMetrics) {
                    Label("Custom date ranges · Pro", systemImage: "lock")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }

            Button {
                isShowingBreakdownFilters = true
            } label: {
                HStack {
                    Label("Refine", systemImage: "slider.horizontal.3")
                    Spacer()
                    Text("\(breakdown.rawValue) · \(selectedCategoryTitle)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PocketLedgerTheme.textTertiary)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .pocketGlassSurface(cornerRadius: 11)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("metrics-secondary-filters")
            .sheet(isPresented: $isShowingBreakdownFilters) {
                NavigationStack {
                    Form {
                        Section("Breakdown") {
                            Picker("Show spending by", selection: $breakdown) {
                                ForEach(MetricsBreakdown.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("metrics-breakdown-picker")
                        }

                        Section("Category") {
                            Picker("Include", selection: $selectedCategoryID) {
                                Text("All categories").tag(UUID?.none)
                                CategoryPickerContent(
                                    categories: store.activeCategories,
                                    includeUncategorized: false
                                )
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .pocketListSurface()
                    .navigationTitle("Breakdown")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingBreakdownFilters = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .padding(4)
        .pocketGlassSurface(cornerRadius: 13)
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    private var selectedCategoryTitle: String {
        guard let selectedCategoryID else { return "All categories" }
        return store.categoryPath(for: selectedCategoryID)
    }

    private var periodNavigator: some View {
        VStack(spacing: 10) {
            if period == .custom {
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("To", selection: $customEnd, displayedComponents: .date)
            } else {
                HStack {
                    if proAccess.hasProAccess || canMoveBackAsFree {
                        Button {
                            movePeriod(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.headline.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Previous period")
                    } else {
                        ProUpgradeButton(feature: .historicalMetrics) {
                            Image(systemName: "chevron.left")
                                .font(.headline.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Unlock older metrics with Pro")
                    }

                    Spacer()

                    Text(periodTitle)
                        .font(.headline.weight(.semibold))
                        .accessibilityIdentifier("metrics-period-title")

                    Spacer()

                    Button {
                        movePeriod(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.headline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next period")
                }
            }

            Text(intervalLabel)
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
        .foregroundStyle(PocketLedgerTheme.textPrimary)
        .padding(.vertical, 12)
    }

    private func totalsHeader(_ snapshot: MetricsSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Income")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Text(Money(currency: selectedCurrency, minorUnits: snapshot.income).formatted)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PocketLedgerTheme.income)
                    .contentTransition(.numericText(value: Double(snapshot.income)))
                    .animation(PocketLedgerMotion.quick(reduceMotion: reduceMotion), value: snapshot.income)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Expenses")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Text(Money(currency: selectedCurrency, minorUnits: snapshot.expenses).formatted)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PocketLedgerTheme.warning)
                    .contentTransition(.numericText(value: Double(snapshot.expenses)))
                    .animation(PocketLedgerMotion.quick(reduceMotion: reduceMotion), value: snapshot.expenses)
            }
        }
        .padding(.bottom, 12)
    }

    private func spendingChart(_ snapshot: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(breakdown == .category ? "Spending by category" : "Spending by account")
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(snapshot.filteredTransactions.count) entries")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }

            if breakdown == .category {
                if snapshot.categories.isEmpty {
                    emptySpendingChart
                } else {
                    categorySpendingChart(snapshot)
                }
            } else {
                if snapshot.accounts.isEmpty {
                    emptySpendingChart
                } else {
                    accountSpendingChart(snapshot)
                }
            }
        }
        .pocketCard()
    }

    private var emptySpendingChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.title2)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
            Text("No expense activity in this range.")
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
    }

    private func categorySpendingChart(_ snapshot: MetricsSnapshot) -> some View {
        ZStack {
            Chart(snapshot.categories) { metric in
                SectorMark(
                    angle: .value("Amount", Double(metric.amount)),
                    innerRadius: .ratio(0.61),
                    angularInset: 1.5
                )
                .foregroundStyle(chartColor(for: metric.colorIndex))
                .annotation(position: .overlay) {
                    if share(for: metric.amount, total: snapshot.expenses) >= 0.08 {
                        Text("\(percentage(for: metric.amount, total: snapshot.expenses))%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 216)

            spendingTotal(snapshot.expenses)
        }
    }

    private func accountSpendingChart(_ snapshot: MetricsSnapshot) -> some View {
        let total = snapshot.accounts.reduce(Int64.zero) { $0 + $1.amount }
        return ZStack {
            Chart(snapshot.accounts) { metric in
                SectorMark(
                    angle: .value("Amount", Double(metric.amount)),
                    innerRadius: .ratio(0.61),
                    angularInset: 1.5
                )
                .foregroundStyle(chartColor(for: metric.colorIndex))
                .annotation(position: .overlay) {
                    if share(for: metric.amount, total: total) >= 0.08 {
                        Text("\(percentage(for: metric.amount, total: total))%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 216)

            spendingTotal(total)
        }
    }

    private func spendingTotal(_ total: Int64) -> some View {
        VStack(spacing: 3) {
            Text(Money(currency: selectedCurrency, minorUnits: total).formatted)
                .font(.headline.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .contentTransition(.numericText(value: Double(total)))
                .animation(PocketLedgerMotion.quick(reduceMotion: reduceMotion), value: total)
            Text("TOTAL SPENT")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(PocketLedgerTheme.textTertiary)
        }
    }

    private func categoryRows(_ snapshot: MetricsSnapshot) -> some View {
        let total = breakdown == .category
            ? snapshot.expenses
            : snapshot.accounts.reduce(Int64.zero) { $0 + $1.amount }

        return VStack(spacing: 0) {
            if breakdown == .category {
                ForEach(snapshot.categories) { metric in
                    NavigationLink {
                        CategoryMetricsDetailView(
                            store: store,
                            security: security,
                            categoryID: metric.categoryID,
                            categoryTitle: metric.title,
                            currency: metric.currency,
                            anchorDate: anchorDate,
                            selectedInterval: interval
                        )
                    } label: {
                        breakdownRow(
                            title: metric.title,
                            icon: categoryIcon(for: metric.categoryID),
                            amount: metric.amount,
                            percentage: percentage(for: metric.amount, total: total),
                            colorIndex: metric.colorIndex
                        )
                    }
                    .buttonStyle(.plain)

                    if metric.id != snapshot.categories.last?.id {
                        Divider().overlay(PocketLedgerTheme.divider)
                    }
                }
            } else {
                ForEach(snapshot.accounts) { metric in
                    NavigationLink {
                        TransactionsView(
                            store: store,
                            security: security,
                            initialFilter: .expense,
                            initialPeriod: .custom,
                            initialAccountID: metric.accountID,
                            initialReportingCurrency: selectedCurrency,
                            initialCustomStartDate: interval.start,
                            initialCustomEndDate: Calendar.current.date(
                                byAdding: .day,
                                value: -1,
                                to: interval.end
                            ) ?? interval.end
                        )
                    } label: {
                        breakdownRow(
                            title: metric.title,
                            icon: store.account(with: metric.accountID)?.type.systemImage ?? "wallet.pass",
                            amount: metric.amount,
                            percentage: percentage(for: metric.amount, total: total),
                            colorIndex: metric.colorIndex
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Show expenses counted for this account in the selected period")

                    if metric.id != snapshot.accounts.last?.id {
                        Divider().overlay(PocketLedgerTheme.divider)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .pocketGroupedSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
        .padding(.top, 12)
    }

    private func breakdownRow(
        title: String,
        icon: String,
        amount: Int64,
        percentage: Int,
        colorIndex: Int
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(percentage)%")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 48, height: 30)
                .background(chartColor(for: colorIndex), in: RoundedRectangle(cornerRadius: 7))

            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chartColor(for: colorIndex))
                .frame(width: 22)

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(Money(currency: selectedCurrency, minorUnits: amount).formatted)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .contentShape(Rectangle())
        .padding(.vertical, 13)
    }

    private func activityMix(_ snapshot: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity mix")
                .font(.title3.weight(.bold))

            HStack(spacing: 10) {
                mixMetric(title: "Expenses", count: snapshot.activityCounts[.expense] ?? 0, tint: PocketLedgerTheme.warning)
                mixMetric(title: "Income", count: snapshot.activityCounts[.income] ?? 0, tint: PocketLedgerTheme.income)
                mixMetric(title: "Transfers", count: snapshot.activityCounts[.transfer] ?? 0, tint: PocketLedgerTheme.positive)
            }
        }
        .pocketCard()
        .padding(.top, 18)
    }

    private func mixMetric(title: String, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.title3.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartColor(for index: Int) -> Color {
        let colors = [
            PocketLedgerTheme.warning,
            PocketLedgerTheme.accent,
            PocketLedgerTheme.income,
            PocketLedgerTheme.positive,
            PocketLedgerTheme.accent.opacity(0.62),
            PocketLedgerTheme.warning.opacity(0.62),
            PocketLedgerTheme.income.opacity(0.62)
        ]
        return colors[index % colors.count]
    }

    private func share(for amount: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(amount) / Double(total)
    }

    private func percentage(for metric: CategoryMetric, total: Int64) -> Int {
        percentage(for: metric.amount, total: total)
    }

    private func percentage(for amount: Int64, total: Int64) -> Int {
        Int((share(for: amount, total: total) * 100).rounded())
    }

    private func categoryIcon(for categoryID: UUID?) -> String {
        store.ledgerIndex.categorySystemImage(for: categoryID)
    }

    private func movePeriod(by value: Int) {
        let component: Calendar.Component = period == .year ? .year : .month
        let nextDate = Calendar.current.date(byAdding: component, value: value, to: anchorDate) ?? anchorDate
        if !proAccess.hasProAccess,
           !PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: nextDate,
            isCalendarYear: period == .year
           ) {
            return
        }
        anchorDate = nextDate
    }

    private var canMoveBackAsFree: Bool {
        let component: Calendar.Component = period == .year ? .year : .month
        let previousDate = Calendar.current.date(byAdding: component, value: -1, to: anchorDate) ?? anchorDate
        return PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: previousDate,
            isCalendarYear: period == .year
        )
    }

    private var canViewSelectedPeriodAsFree: Bool {
        period != .custom && PocketLedgerTierPolicy.canViewHistoricalPeriod(
            start: interval.start,
            isCalendarYear: period == .year
        )
    }

    private var periodTitle: String {
        switch period {
        case .month:
            return anchorDate.formatted(.dateTime.month(.abbreviated).year())
        case .year:
            return anchorDate.formatted(.dateTime.year())
        case .custom:
            return intervalLabel
        }
    }

    private var intervalLabel: String {
        let start = interval.start.formatted(.dateTime.month(.abbreviated).day().year())
        let endDate = interval.end.addingTimeInterval(-1)
        let end = endDate.formatted(.dateTime.month(.abbreviated).day().year())
        return start == end ? start : "\(start) – \(end)"
    }

    private var reportErrorPresented: Binding<Bool> {
        Binding(
            get: { reportError != nil },
            set: { if !$0 { reportError = nil } }
        )
    }

    private func refreshSnapshot() {
        withAnimation(PocketLedgerMotion.expressive(reduceMotion: reduceMotion)) {
            snapshot = MetricsSnapshot.make(
                index: store.ledgerIndex,
                interval: interval,
                selectedCurrency: selectedCurrency,
                selectedCategoryID: selectedCategoryID
            )
        }
    }

    private func generateReport(transactionLimit: Int?) {
        guard proAccess.hasProAccess else { return }
        let currentSnapshot = snapshot

        var spendingByCurrency: [LedgerCurrency: Int64] = [:]
        for transaction in currentSnapshot.filteredTransactions where transaction.kind == .expense {
            for movement in transaction.outflows {
                guard store.ledgerIndex.includesInTotals(accountID: movement.accountID),
                      let amount = financeConvertedMinorUnits(
                          movement.money,
                          to: selectedCurrency,
                          using: transaction.exchangeRate
                      ) else {
                    continue
                }
                spendingByCurrency[movement.money.currency, default: 0] += amount
            }
            for movement in transaction.inflows {
                guard store.ledgerIndex.includesInTotals(accountID: movement.accountID),
                      let amount = financeConvertedMinorUnits(
                          movement.money,
                          to: selectedCurrency,
                          using: transaction.exchangeRate
                      ) else {
                    continue
                }
                spendingByCurrency[movement.money.currency, default: 0] -= amount
            }
        }
        let positiveCurrencyTotals = spendingByCurrency
            .filter { $0.value > 0 }
            .sorted {
                $0.value == $1.value
                    ? $0.key.rawValue < $1.key.rawValue
                    : $0.value > $1.value
            }
        let currencyTotal = positiveCurrencyTotals.reduce(Int64.zero) { $0 + $1.value }
        let allTransactions = currentSnapshot.filteredTransactions
        let selectedTransactions = transactionLimit.map { Array(allTransactions.prefix(max(0, $0))) }
            ?? allTransactions
        let reportTransactions = selectedTransactions.map { transaction in
            let outflow = store.ledgerIndex.movementTotal(
                transaction.outflows,
                currency: selectedCurrency,
                exchangeRate: transaction.exchangeRate
            )
            let inflow = store.ledgerIndex.movementTotal(
                transaction.inflows,
                currency: selectedCurrency,
                exchangeRate: transaction.exchangeRate
            )
            let amount: String
            switch transaction.kind {
            case .expense:
                amount = Money(
                    currency: selectedCurrency,
                    minorUnits: store.ledgerIndex.netExpenseAmount(transaction, currency: selectedCurrency)
                ).formatted
            case .income:
                amount = Money(currency: selectedCurrency, minorUnits: inflow).formatted
            case .transfer:
                amount = "\(Money(currency: selectedCurrency, minorUnits: outflow).formatted) → \(Money(currency: selectedCurrency, minorUnits: inflow).formatted)"
            }
            return MetricsReportTransaction(
                date: transaction.date,
                note: transaction.note,
                kind: transaction.kind,
                category: store.ledgerIndex.categoryPath(for: transaction.categoryID),
                amount: amount
            )
        }
        let report = MetricsReportData(
            periodTitle: periodTitle,
            dateRange: intervalLabel,
            currency: selectedCurrency,
            categoryScope: selectedCategoryID.map { store.categoryPath(for: $0) } ?? "All categories",
            income: Money(currency: selectedCurrency, minorUnits: currentSnapshot.income),
            expenses: Money(currency: selectedCurrency, minorUnits: currentSnapshot.expenses),
            entryCount: currentSnapshot.filteredTransactions.count,
            activityCounts: currentSnapshot.activityCounts,
            categories: currentSnapshot.categories.map {
                MetricsReportCategory(
                    title: $0.title,
                    amount: Money(currency: $0.currency, minorUnits: $0.amount),
                    count: $0.count,
                    percentage: percentage(for: $0, total: currentSnapshot.expenses)
                )
            },
            currencyBreakdown: positiveCurrencyTotals.map { currency, amount in
                MetricsReportSeries(
                    title: currency.rawValue,
                    amount: Money(currency: selectedCurrency, minorUnits: amount),
                    percentage: currencyTotal > 0 ? Int((Double(amount) / Double(currencyTotal) * 100).rounded()) : 0
                )
            },
            transactions: reportTransactions,
            totalTransactionCount: allTransactions.count,
            includesTransactions: transactionLimit != 0,
            generatedAt: .now
        )

        do {
            let url = try MetricsReportPDF.writeShareableFile(for: report)
            reportToShare = MetricsReportShareItem(url: url)
        } catch {
            reportError = error.localizedDescription
        }
    }
}

@MainActor
private struct CategoryMetricsDetailView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @ObservedObject private var proAccess = ProEntitlementStore.shared

    let categoryID: UUID?
    let categoryTitle: String
    let currency: LedgerCurrency
    @State private var selectedInterval: DateInterval

    @State private var anchorDate: Date
    @State private var snapshot = CategoryMetricsDetailSnapshot.empty
    @State private var editingTransaction: LedgerTransaction?
    @State private var transactionToTemplate: LedgerTransaction?
    @State private var deletedTransactionsForUndo: [LedgerTransaction] = []
    @State private var transactionDeletionError: String?
    @State private var transactionToOpenID: UUID?
    @State private var isShowingTransactionDetail = false

    init(
        store: LedgerStore,
        security: AppSecurityService,
        categoryID: UUID?,
        categoryTitle: String,
        currency: LedgerCurrency,
        anchorDate: Date,
        selectedInterval: DateInterval
    ) {
        self.store = store
        self.security = security
        self.categoryID = categoryID
        self.categoryTitle = categoryTitle
        self.currency = currency
        _selectedInterval = State(initialValue: selectedInterval)
        _anchorDate = State(initialValue: anchorDate)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            PocketGlassContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader
                    lineChart(snapshot)
                    detailCategoryRow(snapshot)
                    subcategoryRows(snapshot)
                    transactionRows(snapshot)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .pocketSwipeActionsContainer()
        .pocketScreen()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !deletedTransactionsForUndo.isEmpty {
                TransactionUndoBanner(
                    transactions: deletedTransactionsForUndo,
                    onUndo: {
                        if store.restoreTransactions(deletedTransactionsForUndo) {
                            deletedTransactionsForUndo.removeAll()
                        } else {
                            transactionDeletionError = store.lastActionStatus ?? "The transaction could not be restored."
                        }
                    },
                    onDismiss: { deletedTransactionsForUndo.removeAll() }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .transactionActionAlert(message: $transactionDeletionError)
        .navigationTitle(categoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingTransactionDetail) {
            if let transactionToOpenID {
                MetricsTransactionDetailView(
                    store: store,
                    security: security,
                    transactionID: transactionToOpenID
                )
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $editingTransaction) { transaction in
            TransactionEditor(store: store, transaction: transaction)
        }
        .sheet(item: $transactionToTemplate) { transaction in
            TemplateNameEditor(store: store, transaction: transaction)
        }
        .onAppear(perform: refreshSnapshot)
        .onChange(of: anchorDate) { _, _ in refreshSnapshot() }
        .onChange(of: store.ledgerRevision) { _, _ in refreshSnapshot() }
        .onChange(of: proAccess.hasProAccess) { _, hasProAccess in
            if !hasProAccess {
                anchorDate = .now
                selectedInterval = Calendar.current.dateInterval(of: .month, for: .now) ?? selectedInterval
            }
            refreshSnapshot()
        }
    }

    private var detailHeader: some View {
        VStack(spacing: 10) {
            HStack {
                if proAccess.hasProAccess || canMoveBackAsFree {
                    Button {
                        moveMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous month")
                } else {
                    ProUpgradeButton(feature: .historicalMetrics) {
                        Image(systemName: "chevron.left")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlock older metrics with Pro")
                }

                Spacer()

                Text(anchorDate.formatted(.dateTime.month(.abbreviated).year()))
                    .font(.headline.weight(.semibold))

                Spacer()

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next month")
            }

            HStack {
                Text("Last 7 months")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                Spacer()
                Text(currency.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PocketLedgerTheme.accent)
            }
        }
        .foregroundStyle(PocketLedgerTheme.textPrimary)
    }

    private func lineChart(_ snapshot: CategoryMetricsDetailSnapshot) -> some View {
        let maximum = max(snapshot.monthlyPoints.map(\.amount).max() ?? 1, 1)
        let currentMonth = Calendar.current.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate

        return Chart(snapshot.monthlyPoints) { point in
            LineMark(
                x: .value("Month", point.date, unit: .month),
                y: .value("Amount", Double(point.amount))
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .foregroundStyle(PocketLedgerTheme.accent)

            PointMark(
                x: .value("Month", point.date, unit: .month),
                y: .value("Amount", Double(point.amount))
            )
            .foregroundStyle(PocketLedgerTheme.accent)
            .symbolSize(point.date == currentMonth ? 80 : 42)
            .annotation(position: .top, spacing: 6) {
                if point.amount > 0 {
                    Text(Money(currency: currency, minorUnits: point.amount).formatted)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
        }
        .chartYScale(domain: 0...Double(maximum))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                    .foregroundStyle(PocketLedgerTheme.divider)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                    .foregroundStyle(PocketLedgerTheme.divider)
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            }
        }
        .frame(height: 205)
        .padding(.top, 8)
    }

    private func detailCategoryRow(_ snapshot: CategoryMetricsDetailSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: categoryIcon)
                .foregroundStyle(PocketLedgerTheme.accent)
                .frame(width: 24)

            Text(categoryTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer()

            Text(Money(currency: currency, minorUnits: snapshot.selectedMonthTotal).formatted)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 14)
        .pocketGroupedSurface(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func subcategoryRows(_ snapshot: CategoryMetricsDetailSnapshot) -> some View {
        if !snapshot.subcategories.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Subcategories")
                    .font(.title3.weight(.bold))
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(snapshot.subcategories) { metric in
                        NavigationLink {
                            CategoryMetricsDetailView(
                                store: store,
                                security: security,
                                categoryID: metric.categoryID,
                                categoryTitle: metric.title,
                                currency: currency,
                                anchorDate: anchorDate,
                                selectedInterval: selectedInterval
                            )
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: store.ledgerIndex.categorySystemImage(for: metric.categoryID))
                                    .foregroundStyle(PocketLedgerTheme.accent)
                                    .frame(width: 24)

                                Text(metric.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                Text(Money(currency: currency, minorUnits: metric.amount).formatted)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)

                        if metric.id != snapshot.subcategories.last?.id {
                            Divider().overlay(PocketLedgerTheme.divider)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .pocketGroupedSurface(cornerRadius: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(PocketLedgerTheme.divider, lineWidth: 1)
                }
            }
        }
    }

    private func transactionRows(_ snapshot: CategoryMetricsDetailSnapshot) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("Transactions")
                .font(.title3.weight(.bold))
                .padding(.top, 20)
                .padding(.bottom, 8)

            if snapshot.selectedMonthTransactions.isEmpty {
                Text("No transactions in this month.")
                    .font(.subheadline)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                    .padding(.vertical, 24)
            } else {
                ForEach(snapshot.selectedMonthTransactions) { transaction in
                    TransactionRow(
                        transaction: transaction,
                        store: store,
                        onEdit: { editingTransaction = transaction },
                        onDuplicate: { _ = store.duplicateTransaction(id: transaction.id) },
                        onDelete: {
                            if store.deleteTransaction(id: transaction.id) {
                                deletedTransactionsForUndo.append(transaction)
                            } else {
                                transactionDeletionError = store.lastActionStatus ?? "The transaction could not be deleted."
                            }
                        },
                        onSaveTemplate: { transactionToTemplate = transaction },
                        allowsActions: true,
                        onOpen: {
                            transactionToOpenID = transaction.id
                            isShowingTransactionDetail = true
                        },
                        subtitleOverride: [
                            accountNames(for: transaction),
                            transaction.date.formatted(.dateTime.month(.abbreviated).day().year())
                        ].filter { !$0.isEmpty }.joined(separator: " · "),
                        amountOverride: "− \(Money(currency: currency, minorUnits: transactionAmount(transaction)).formatted)",
                        amountColorOverride: PocketLedgerTheme.warning,
                        usesScrollSwipeActions: true
                    )

                    if transaction.id != snapshot.selectedMonthTransactions.last?.id {
                        Divider().overlay(PocketLedgerTheme.divider)
                    }
                }
            }
        }
    }

    private var categoryIcon: String {
        store.ledgerIndex.categorySystemImage(for: categoryID)
    }

    private func transactionAmount(_ transaction: LedgerTransaction) -> Int64 {
        store.ledgerIndex.netExpenseAmount(transaction, currency: currency)
    }

    private func accountNames(for transaction: LedgerTransaction) -> String {
        let names = transaction.outflows.compactMap { movement -> String? in
            guard store.ledgerIndex.includesInTotals(accountID: movement.accountID) else { return nil }
            return store.ledgerIndex.account(with: movement.accountID)?.name
        }
        return names.isEmpty ? "Expense" : names.joined(separator: ", ")
    }

    private func refreshSnapshot() {
        snapshot = CategoryMetricsDetailSnapshot.make(
            index: store.ledgerIndex,
            categoryID: categoryID,
            currency: currency,
            anchorDate: anchorDate,
            selectedInterval: selectedInterval
        )
    }

    private func moveMonth(by value: Int) {
        let nextDate = Calendar.current.date(byAdding: .month, value: value, to: anchorDate) ?? anchorDate
        if !proAccess.hasProAccess,
           !PocketLedgerTierPolicy.canViewHistoricalPeriod(start: nextDate, isCalendarYear: false) {
            return
        }
        anchorDate = nextDate
    }

    private var canMoveBackAsFree: Bool {
        let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: anchorDate) ?? anchorDate
        return PocketLedgerTierPolicy.canViewHistoricalPeriod(start: previousMonth, isCalendarYear: false)
    }
}

@MainActor
private struct MetricsTransactionDetailView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    let transactionID: UUID

    @State private var editingTransaction: LedgerTransaction?

    private var transaction: LedgerTransaction? {
        store.data.transactions.first { $0.id == transactionID }
    }

    var body: some View {
        Group {
            if let transaction {
                ScrollView(showsIndicators: false) {
                    PocketGlassContainer(spacing: 14) {
                        VStack(alignment: .leading, spacing: 16) {
                            transactionHeader(transaction)
                            movementSection(
                                title: "Paid from",
                                movements: transaction.outflows,
                                tint: PocketLedgerTheme.warning
                            )
                            movementSection(
                                title: "Received in",
                                movements: transaction.inflows,
                                tint: PocketLedgerTheme.income
                            )
                            metadataSection(transaction)
                        }
                        .padding(.horizontal, PocketLedgerTheme.screenHorizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                }
            } else {
                ContentUnavailableView("Transaction unavailable", systemImage: "doc.questionmark")
            }
        }
        .pocketScreen()
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            PocketLedgerToolbar(security: security) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit", systemImage: "pencil") {
                        editingTransaction = transaction
                    }
                    .disabled(transaction == nil)
                    .accessibilityIdentifier("metrics-transaction-edit")
                }
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionEditor(store: store, transaction: transaction)
        }
    }

    private func transactionHeader(_ transaction: LedgerTransaction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: transactionIcon(transaction.kind))
                .font(.title2)
                .foregroundStyle(transactionTint(transaction.kind))
                .frame(width: 46, height: 46)
                .background(transactionTint(transaction.kind).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.kind.displayName)
                    .font(.headline.weight(.semibold))
                if !transaction.note.isEmpty {
                    Text(transaction.note)
                        .font(.subheadline)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                        .lineLimit(2)
                }
                Text(transaction.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .pocketGroupedSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func movementSection(
        title: String,
        movements: [MoneyMovement],
        tint: Color
    ) -> some View {
        if !movements.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3.weight(.bold))

                VStack(spacing: 0) {
                    ForEach(movements) { movement in
                        HStack(spacing: 10) {
                            Image(systemName: "wallet.pass")
                                .foregroundStyle(tint)
                                .frame(width: 24)

                            Text(store.ledgerIndex.account(with: movement.accountID)?.name ?? "Unknown account")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(movement.money.formatted)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)

                        if movement.id != movements.last?.id {
                            Divider().overlay(PocketLedgerTheme.divider)
                        }
                    }
                }
                .pocketGroupedSurface(cornerRadius: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(PocketLedgerTheme.divider, lineWidth: 1)
                }
            }
        }
    }

    private func metadataSection(_ transaction: LedgerTransaction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("Category", store.ledgerIndex.categoryPath(for: transaction.categoryID))
            detailRow("Type", transaction.kind.displayName)

            if let amountDue = transaction.amountDue {
                detailRow("Bill total", amountDue.formatted)
            }
            if let exchangeRate = transaction.exchangeRate {
                detailRow("Exchange rate", exchangeRate.summary)
            }
            if let shortfall = transaction.changeAdjustment?.shortfall {
                detailRow("Change shortfall", shortfall.formatted)
            }
        }
        .pocketGroupedSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PocketLedgerTheme.divider, lineWidth: 1)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func transactionIcon(_ kind: TransactionKind) -> String {
        switch kind {
        case .expense:
            return "arrow.up.right"
        case .income:
            return "arrow.down.left"
        case .transfer:
            return "arrow.left.arrow.right"
        }
    }

    private func transactionTint(_ kind: TransactionKind) -> Color {
        switch kind {
        case .expense:
            return PocketLedgerTheme.warning
        case .income:
            return PocketLedgerTheme.income
        case .transfer:
            return PocketLedgerTheme.accent
        }
    }
}
