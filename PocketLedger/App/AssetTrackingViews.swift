import SwiftUI
import Charts

private struct PhysicalAssetGainHistoryPoint: Identifiable {
    let date: Date
    let gainLoss: Money
    var id: Date { date }
}

@MainActor
struct PhysicalAssetGainHistoryChart: View {
    let account: Account
    let areBalancesRevealed: Bool
    @State private var selectedMetal: PreciousMetal? = nil

    private var history: [PhysicalAssetGainSnapshot] {
        account.tracking?.physicalAssetGainHistory ?? []
    }

    private var availableMetals: [PreciousMetal] {
        PreciousMetal.allCases.filter { metal in
            account.tracking?.metalPurchases.contains { $0.metal == metal } == true
        }
    }

    private var selectedHistoryMetal: PreciousMetal? {
        guard let selectedMetal, availableMetals.contains(selectedMetal) else { return nil }
        return selectedMetal
    }

    private var chartPoints: [PhysicalAssetGainHistoryPoint] {
        history.sorted { $0.date < $1.date }.suffix(365).compactMap { snapshot in
            let gainLoss: Money?
            if let metal = selectedHistoryMetal {
                gainLoss = snapshot.gainLossByMetal?[metal]
            } else {
                gainLoss = snapshot.gainLoss
            }
            return gainLoss.map { PhysicalAssetGainHistoryPoint(date: snapshot.date, gainLoss: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gain/loss over time")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textPrimary)

                Spacer(minLength: 8)
                if !availableMetals.isEmpty {
                    Menu {
                        Button {
                            selectedMetal = nil
                        } label: {
                            if selectedHistoryMetal == nil {
                                Label("All metals", systemImage: "checkmark")
                            } else {
                                Text("All metals")
                            }
                        }
                        ForEach(availableMetals) { metal in
                            Button {
                                selectedMetal = metal
                            } label: {
                                if selectedHistoryMetal == metal {
                                    Label(metal.displayName, systemImage: "checkmark")
                                } else {
                                    Text(metal.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(selectedHistoryMetal?.displayName ?? "All metals", systemImage: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketLedgerTheme.accent)
                    }
                    .accessibilityLabel("Choose metal for gain/loss chart")
                }
            }

            if !areBalancesRevealed {
                Text("Reveal balances to view this history chart.")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            } else if availableMetals.isEmpty {
                Text("Add a gold or silver holding to start daily tracking.")
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            } else if chartPoints.isEmpty {
                Text(emptyHistoryMessage)
                    .font(.caption)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
            } else {
                if let currentPoint = chartPoints.last {
                    HStack {
                        Text("Latest · \(currentPoint.date.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        ProtectedAmountText(
                            value: currentPoint.gainLoss.minorUnits > 0
                                ? "+\(currentPoint.gainLoss.formatted)"
                                : currentPoint.gainLoss.formatted,
                            isRevealed: areBalancesRevealed
                        )
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(currentPoint.gainLoss.minorUnits >= 0 ? PocketLedgerTheme.positive : .red)
                    }
                }

                let values = chartPoints.map {
                    Double($0.gainLoss.minorUnits) / Double(account.currency.minorUnitScale)
                }
                let lowerBound = min(values.min() ?? 0, 0)
                let upperBound = max(values.max() ?? 0, 0)
                let padding = max((upperBound - lowerBound) * 0.12, 1)

                Chart {
                    RuleMark(y: .value("Break-even", 0))
                        .foregroundStyle(PocketLedgerTheme.divider)

                    ForEach(chartPoints) { point in
                        let value = Double(point.gainLoss.minorUnits) / Double(account.currency.minorUnitScale)
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Gain/loss", value)
                        )
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(PocketLedgerTheme.accent)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Gain/loss", value)
                        )
                        .foregroundStyle(PocketLedgerTheme.accent)
                        .symbolSize(24)
                    }
                }
                .chartYScale(domain: (lowerBound - padding)...(upperBound + padding))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(PocketLedgerTheme.divider)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.currency(code: account.currency.rawValue)))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(PocketLedgerTheme.divider)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
                .frame(height: 190)

                Text("Daily snapshots · last 365 days")
                    .font(.caption2)
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
            }
        }
    }

    private var emptyHistoryMessage: String {
        if history.isEmpty {
            return "Daily history starts once a current metal price is available."
        }
        if selectedHistoryMetal == nil {
            return "Choose a metal to see its individual history."
        }
        return "Daily history for this metal starts once its current price is available."
    }
}

@MainActor
struct AssetPurchaseEditor: View {
    @ObservedObject var store: LedgerStore
    let accountType: AccountType
    var onSave: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: UUID?
    @State private var isCreatingAccount = false

    private var purchaseAccounts: [Account] {
        store.activeAccounts.filter {
            $0.type == accountType && (accountType != .physicalAsset || $0.tracking?.physicalAssetSubtype != .other)
        }
    }

    private var selectedAccount: Account? {
        guard let selectedAccountID, let account = store.account(with: selectedAccountID),
              accountType != .physicalAsset || account.tracking?.physicalAssetSubtype != .other else { return nil }
        return account
    }

    var body: some View {
        Group {
            if let account = selectedAccount {
                if accountType == .physicalAsset {
                    MetalPurchaseEditor(store: store, account: account, historical: false, onSave: onSave)
                } else {
                    InvestmentPurchaseEditor(store: store, account: account, onSave: onSave)
                }
            } else {
                NavigationStack {
                    List {
                        Section {
                            ForEach(purchaseAccounts) { account in
                                Button {
                                    selectedAccountID = account.id
                                } label: {
                                    Label(account.name, systemImage: account.type.systemImage)
                                }
                            }
                            Button("Create account", systemImage: "plus") { isCreatingAccount = true }
                        } header: {
                            Text("Choose an account")
                        } footer: {
                            Text(accountType == .physicalAsset
                                 ? "Gold and silver purchases move money into the asset account as a transfer. Other assets use manual valuations and sale tracking."
                                 : "A purchase moves money into an investment account. It is a transfer and does not count as spending.")
                        }
                    }
                    .pocketListSurface()
                    .navigationTitle(accountType == .physicalAsset ? "Physical asset purchase" : "Investment purchase")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    }
                }
            }
        }
        .sheet(isPresented: $isCreatingAccount) {
            AccountEditor(store: store, initialType: accountType, onSaved: { account in
                if account.type == accountType,
                   accountType != .physicalAsset || account.tracking?.physicalAssetSubtype != .other {
                    selectedAccountID = account.id
                }
            })
        }
    }
}

@MainActor
private struct InvestmentPurchaseEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fundingID: UUID?
    @State private var amount = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var errorMessage: String?

    private var fundingAccounts: [Account] {
        store.activeAccounts.filter { $0.currency == account.currency && ($0.type == .cash || $0.type == .bankAccount) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Investment purchase") {
                    LabeledContent("Investment account", value: account.name)
                    CurrencyInputField("Amount invested", text: $amount, currency: account.currency)
                    DatePicker("Purchase date", selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
                Section {
                    Picker("Paid from", selection: $fundingID) {
                        Text("Choose account").tag(Optional<UUID>.none)
                        ForEach(fundingAccounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                } header: {
                    Text("Funding")
                } footer: {
                    Text("Moves money from a cash or bank account in \(account.currency.rawValue) into this investment. This is a transfer, not an expense. Update gain/loss separately from the investment account.")
                }
            }
            .pocketListSurface()
            .navigationTitle("Investment purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Purchase not saved", message: $errorMessage)
        }
    }

    private func save() {
        guard let money = Money.parse(amount, currency: account.currency), money.minorUnits > 0,
              let fundingID, fundingAccounts.contains(where: { $0.id == fundingID }), date <= Date() else {
            errorMessage = "Enter a positive amount, choose a cash or bank account, and use a purchase date that is not in the future."
            return
        }
        let transaction = LedgerTransaction(date: date, note: note.isEmpty ? "Investment purchase" : note, kind: .transfer, categoryID: nil,
            outflows: [MoneyMovement(accountID: fundingID, money: money)], inflows: [MoneyMovement(accountID: account.id, money: money)])
        if store.addTransaction(transaction) {
            onSave()
            dismiss()
        } else {
            errorMessage = store.lastActionStatus ?? "Purchase could not be saved."
        }
    }
}

@MainActor
struct AssetTrackingSection: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let areBalancesRevealed: Bool

    @State private var sheet: AssetSheet?

    private enum AssetSheet: Identifiable {
        case purchase, pricing(PreciousMetal), investment(Bool), sale
        var id: String {
            switch self {
            case .purchase: "purchase"
            case .pricing(let metal): "price-\(metal.rawValue)"
            case .investment(let realizing): "investment-\(realizing)"
            case .sale: "sale"
            }
        }
    }

    var body: some View {
        Group {
            if account.type == .physicalAsset {
                if account.tracking?.physicalAssetSubtype == .other {
                    investment
                } else {
                    metals
                }
            } else if account.type == .investment {
                investment
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if account.type == .physicalAsset && account.tracking?.physicalAssetSubtype != .other {
                Task { await store.refreshMetalPrices() }
            }
        }) { item in
            switch item {
            case .purchase:
                MetalPurchaseEditor(store: store, account: account)
            case .pricing(let metal):
                MetalPricingEditor(store: store, account: account, metal: metal)
            case .investment(let realizing):
                InvestmentEntryEditor(store: store, account: account, realizing: realizing)
            case .sale:
                OtherAssetSaleEditor(store: store, account: account)
            }
        }
        .onChange(of: areBalancesRevealed) { _, revealed in
            if !revealed { sheet = nil }
        }
        .task {
            if account.type == .physicalAsset && account.tracking?.physicalAssetSubtype != .other {
                await store.refreshMetalPrices()
            }
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            ProtectedAmountText(value: value, isRevealed: areBalancesRevealed)
                .foregroundStyle(PocketLedgerTheme.textPrimary)
                .monospacedDigit().privacySensitive()
                .accessibilityLabel(areBalancesRevealed ? value : "Hidden value")
        }
        .foregroundStyle(PocketLedgerTheme.textSecondary)
    }

    @ViewBuilder private var metals: some View {
        let purchases = account.tracking?.metalPurchases ?? []
        let metalName = account.tracking?.physicalAssetSubtype?.metal?.displayName ?? "Gold and silver"
        let heldMetals = PreciousMetal.allCases.filter { metal in
            purchases.contains { $0.metal == metal && $0.remainingWeightGrams > 0 }
        }
        let displayedMetals = account.tracking?.physicalAssetSubtype?.metal.map { [$0] } ?? heldMetals
        let automaticMetals = Set((account.tracking?.metalPricing ?? []).filter(\.isAutomaticEnabled).map(\.metal))
        let showsRefreshButton = displayedMetals.contains { automaticMetals.contains($0) }
        let metalPriceRowCount = displayedMetals.count + (showsRefreshButton ? 1 : 0)

        Section {
            VStack(alignment: .leading, spacing: 16) {
                if purchases.isEmpty {
                    Text("Track \(metalName.lowercased()) by purchase, weight and purity.")
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                } else {
                    valueRow("Recorded balance", store.balance(for: account).formatted)
                    valueRow("Estimated metal value", store.valuation(for: account).formatted)
                }
                Button(account.tracking?.physicalAssetSubtype?.metal.map { "Add \($0.displayName.lowercased()) purchase" } ?? "Add metal purchase") { sheet = .purchase }
                    .buttonStyle(.bordered)
                    .tint(PocketLedgerTheme.accent)
                    .disabled(!areBalancesRevealed || account.isArchived)
                if !areBalancesRevealed {
                    Text("Reveal balances to view or update holdings.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .pocketGroupedListRow(index: 0, count: 1)
            .listRowSeparator(.hidden)
        } header: { Text(account.tracking?.physicalAssetSubtype?.metal?.displayName ?? "Metals") } footer: {
            Text(purchases.isEmpty
                 ? "Market price is shown per gram. Add a purchase to track weight and estimate the account's total value."
                 : "Estimated metal value excludes jewelry workmanship and retail premiums. Missing prices use purchase cost in totals.")
                .font(.footnote)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
        }
        .listSectionSeparator(.hidden)
        if !purchases.isEmpty {
            Section("Purchases") {
                ForEach(Array(purchases.enumerated()), id: \.element.id) { entry in
                    let purchase = entry.element
                    NavigationLink {
                        MetalPurchaseDetailView(store: store, accountID: account.id, purchaseID: purchase.id)
                    } label: {
                        MetalPurchaseRow(
                            store: store,
                            account: account,
                            purchase: purchase,
                            areBalancesRevealed: areBalancesRevealed
                        )
                    }
                    .buttonStyle(.plain)
                    .pocketGroupedListRow(index: entry.offset, count: purchases.count)
                    .listRowSeparator(.hidden)
                }
            }
            .listSectionSeparator(.hidden)
        }
        if !displayedMetals.isEmpty {
            Section("Metal prices") {
                ForEach(Array(displayedMetals.enumerated()), id: \.element.id) { entry in
                    let metal = entry.element
                    VStack(alignment: .leading, spacing: 10) {
                        Button("\(metal.displayName) pricing") { sheet = .pricing(metal) }
                            .buttonStyle(.plain)
                            .disabled(!areBalancesRevealed || account.isArchived)
                        if let price = store.metalPricePerGram(account: account, metal: metal) {
                            valueRow("Pure metal / gram", "\(assetNumber(price)) \(account.currency.rawValue)")
                        } else {
                            Text("Price needed").foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                        Text(store.metalQuoteDescription(account: account, metal: metal))
                            .font(.caption).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .pocketGroupedListRow(index: entry.offset, count: metalPriceRowCount)
                    .listRowSeparator(.hidden)
                }
                if showsRefreshButton {
                    Button {
                        Task { await store.refreshMetalPrices(force: true) }
                    } label: {
                        Label("Refresh market prices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .pocketGroupedListRow(index: displayedMetals.count, count: metalPriceRowCount)
                    .listRowSeparator(.hidden)
                }
            }
            .listSectionSeparator(.hidden)
        }
    }

    @ViewBuilder private var investment: some View {
        let isOtherAsset = account.type == .physicalAsset && account.tracking?.physicalAssetSubtype == .other

        Section(isOtherAsset ? "Other asset value" : "Investment performance") {
            VStack(alignment: .leading, spacing: 14) {
                valueRow(isOtherAsset ? "Remaining cost basis" : "Recorded balance", store.balance(for: account).formatted)
                valueRow("Unrealized gain/loss", Money(currency: account.currency, minorUnits: account.tracking?.unrealizedMinorUnits ?? 0).formatted)
                valueRow("Estimated total value", store.valuation(for: account).formatted)
                if let entry = account.tracking?.lastValuation {
                    LabeledContent("Last valuation", value: entry.date.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Entered", value: entry.enteredAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text(isOtherAsset ? "Starting value is the current estimate. Update it as the asset changes." : "No valuation entered yet.")
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Text(isOtherAsset
                     ? "Update the estimated value as the asset changes. Selling all or part transfers the proceeds and records the realized gain or loss."
                     : "Update the gain or loss to reflect today’s investment value. Realize it when a gain or loss is confirmed; use a transfer to move money out.")
                    .font(.footnote)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Button(isOtherAsset ? "Update estimated value" : "Update unrealized gain/loss") { sheet = .investment(false) }
                    .disabled(!areBalancesRevealed || account.isArchived)
                if isOtherAsset {
                    Button("Sell all or part") { sheet = .sale }
                        .disabled(!areBalancesRevealed || store.valuation(for: account).minorUnits <= 0 || account.isArchived)
                } else {
                    Button("Realize gain/loss") { sheet = .investment(true) }
                        .disabled(!areBalancesRevealed || (account.tracking?.unrealizedMinorUnits ?? 0) == 0 || account.isArchived)
                    Text("Realizing a gain or loss preserves estimated total value.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                if !areBalancesRevealed {
                    Text("Reveal balances to update investment performance.").font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .buttonStyle(.bordered)
            .pocketGroupedListRow(index: 0, count: 1)
            .listRowSeparator(.hidden)
        }
        .listSectionSeparator(.hidden)
        if let entries = account.tracking?.investmentEntries, !entries.isEmpty {
            Section("Performance history") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(entries.suffix(20).reversed())) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            valueRow(
                                entry.kind == .valuation
                                    ? (isOtherAsset ? "Unrealized gain/loss" : "Unrealized valuation")
                                    : entry.kind == .sale ? "Sale gain/loss" : "Realized gain/loss",
                                entry.amount.formatted
                            )
                            if entry.kind == .sale {
                                if let cost = entry.saleCostBasis { valueRow("Cost basis sold", cost.formatted) }
                                if let proceeds = entry.saleProceeds { valueRow("Sale proceeds", proceeds.formatted) }
                                if let destinationID = entry.saleDestinationAccountID,
                                   let destination = store.account(with: destinationID) {
                                    Text("Received in \(destination.name)")
                                        .font(.caption).foregroundStyle(PocketLedgerTheme.textSecondary)
                                }
                            }
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(PocketLedgerTheme.textSecondary)
                            Text("Entered \(entry.enteredAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(PocketLedgerTheme.textSecondary)
                        }
                    }
                    if entries.count > 20 {
                        Text("Showing the latest 20 entries.").font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .pocketGroupedListRow(index: 0, count: 1)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }
    }
}

@MainActor
private struct MetalPurchaseRow: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let purchase: MetalPurchase
    let areBalancesRevealed: Bool

    private var valuation: Money? { store.metalValuation(account: account, purchase: purchase) }
    private var gain: Money? { valuation.flatMap { metalPurchaseGain(value: $0, cost: purchase.remainingCost) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PocketIcon(
                    systemImage: "circle.fill",
                    tint: purchase.metal == .gold ? .yellow : .gray,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 3) {
                    ProtectedAmountText(value: purchase.description.isEmpty ? "\(purchase.metal.displayName) purchase" : purchase.description, isRevealed: areBalancesRevealed)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(purchase.metal.displayName) · \(purchase.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer(minLength: 8)
            }

            HStack(alignment: .top, spacing: 12) {
                valueMetric(
                    title: "Current value",
                    value: valuation?.formatted ?? "Price needed",
                    isProtected: valuation != nil
                )
                Spacer(minLength: 8)
                valueMetric(
                    title: purchase.sales.isEmpty ? "Purchase cost" : "Cost remaining",
                    value: purchase.remainingCost.formatted,
                    trailing: true
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "scalemass")
                    .accessibilityHidden(true)
                ProtectedAmountText(value: "\(assetNumber(purchase.remainingQuantity)) of \(assetNumber(purchase.quantity)) remaining · \(assetNumber(purchase.remainingWeightGrams)) g", isRevealed: areBalancesRevealed)
                    .accessibilityLabel(areBalancesRevealed
                        ? "\(assetNumber(purchase.remainingQuantity)) of \(assetNumber(purchase.quantity)) remaining, \(assetNumber(purchase.remainingWeightGrams)) grams"
                        : "Hidden holding quantities")
                Spacer(minLength: 0)
                if let gain {
                    ProtectedAmountText(value: signedMetalGain(gain), isRevealed: areBalancesRevealed)
                        .fontWeight(.semibold)
                        .foregroundStyle(gain.minorUnits >= 0 ? PocketLedgerTheme.positive : .red)
                        .accessibilityLabel(areBalancesRevealed ? signedMetalGain(gain) : "Hidden gain or loss")
                }
            }
            .font(.caption)
            .foregroundStyle(PocketLedgerTheme.textSecondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens purchase details")
    }

    private func valueMetric(
        title: String,
        value: String,
        trailing: Bool = false,
        isProtected: Bool = true
    ) -> some View {
        let alignment: HorizontalAlignment = trailing ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
            ProtectedAmountText(value: value, isRevealed: areBalancesRevealed || !isProtected)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(2)
                .privacySensitive()
                .accessibilityLabel(areBalancesRevealed || !isProtected ? value : "Hidden amount")
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

}

@MainActor
private struct MetalPurchaseDetailView: View {
    @ObservedObject var store: LedgerStore
    let accountID: UUID
    let purchaseID: UUID

    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
    @Environment(\.dismiss) private var dismiss
    @State private var salePurchase: MetalPurchase?

    private var account: Account? { store.account(with: accountID) }
    private var purchase: MetalPurchase? {
        account?.tracking?.metalPurchases.first { $0.id == purchaseID }
    }

    var body: some View {
        Group {
            if let account, let purchase {
                detailList(account: account, purchase: purchase)
            } else {
                ContentUnavailableView("Purchase unavailable", systemImage: "shippingbox")
            }
        }
        .navigationTitle("Metal purchase")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back to account")
            }
        }
        .pocketScreen()
        .sheet(item: $salePurchase, onDismiss: {
            Task { await store.refreshMetalPrices() }
        }) { salePurchase in
            if let account = store.account(with: accountID) {
                MetalSaleEditor(store: store, account: account, purchase: salePurchase)
            }
        }
        .onChange(of: areBalancesRevealed) { _, revealed in
            if !revealed { salePurchase = nil }
        }
    }

    private func detailList(account: Account, purchase: MetalPurchase) -> some View {
        let valuation = store.metalValuation(account: account, purchase: purchase)
        let gain = valuation.flatMap { metalPurchaseGain(value: $0, cost: purchase.remainingCost) }
        let pricePerGram = store.metalPricePerGram(account: account, metal: purchase.metal)

        return List {
            Section("Market value") {
                VStack(alignment: .leading, spacing: 14) {
                    if let valuation {
                        protectedRow("Estimated metal value", valuation.formatted)
                    } else {
                        LabeledContent("Estimated metal value", value: "Price needed")
                        Text("Set a manual price or refresh a quote to calculate current value and unrealized gain.")
                            .font(.footnote)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                    protectedRow("Remaining cost basis", purchase.remainingCost.formatted)
                    if let gain {
                        protectedRow("Unrealized gain/loss", signedMetalGain(gain))
                        if let returnPercentage = metalPurchaseReturnPercentage(gain: gain, cost: purchase.remainingCost) {
                            protectedRow("Return", "\(assetNumber(returnPercentage))%")
                        }
                    }
                    if let pricePerGram {
                        protectedRow("Pure-metal price per gram", "\(assetNumber(pricePerGram)) \(account.currency.rawValue)")
                    }
                    Text(store.metalQuoteDescription(account: account, metal: purchase.metal))
                        .font(.footnote)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .pocketGroupedListRow(index: 0, count: 1)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section("Purchase details") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Metal", value: purchase.metal.displayName)
                    if !purchase.description.isEmpty {
                        protectedRow("Description", purchase.description)
                    }
                    LabeledContent("Purchase date", value: purchase.date.formatted(date: .long, time: .omitted))
                    protectedRow("Quantity purchased", assetNumber(purchase.quantity))
                    protectedRow("Weight per item", "\(assetNumber(purchase.weightPerItem)) \(purchase.unit.displayName.lowercased())")
                    protectedRow("Total weight purchased", "\(assetNumber(purchase.weightGrams)) g")
                    protectedRow("Purity", "\(assetNumber(purchase.purity * 100))%")
                    protectedRow("Pure-metal weight at purchase", "\(assetNumber(purchase.weightGrams * purchase.purity)) g")
                    protectedRow("Total paid including fees", purchase.totalCost.formatted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .pocketGroupedListRow(index: 0, count: 1)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section("Remaining holding") {
                VStack(alignment: .leading, spacing: 14) {
                    protectedRow("Quantity remaining", assetNumber(purchase.remainingQuantity))
                    protectedRow("Weight remaining", "\(assetNumber(purchase.remainingWeightGrams)) g")
                    protectedRow("Pure-metal weight remaining", "\(assetNumber(purchase.pureWeightGrams)) g")
                    protectedRow("Purchase cost remaining", purchase.remainingCost.formatted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .pocketGroupedListRow(index: 0, count: 1)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section("Sales") {
                VStack(alignment: .leading, spacing: 14) {
                    if purchase.sales.isEmpty {
                        Text("No sales recorded for this purchase.")
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    } else {
                        ForEach(purchase.sales) { sale in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(sale.date.formatted(date: .abbreviated, time: .omitted))
                                    Spacer()
                                    ProtectedAmountText(value: sale.proceeds.formatted, isRevealed: areBalancesRevealed)
                                        .fontWeight(.semibold)
                                        .monospacedDigit()
                                        .privacySensitive()
                                        .accessibilityLabel(areBalancesRevealed ? sale.proceeds.formatted : "Hidden value")
                                }
                                HStack {
                                    ProtectedAmountText(value: "\(assetNumber(sale.weightGrams)) g sold", isRevealed: areBalancesRevealed)
                                        .privacySensitive()
                                        .accessibilityLabel(areBalancesRevealed
                                            ? "\(assetNumber(sale.weightGrams)) grams sold"
                                            : "Hidden sale weight")
                                    Spacer()
                                    ProtectedAmountText(value: "Realized \(signedMetalGain(sale.gain))", isRevealed: areBalancesRevealed)
                                        .privacySensitive()
                                        .accessibilityLabel(areBalancesRevealed
                                            ? "Realized \(signedMetalGain(sale.gain))"
                                            : "Hidden realized gain or loss")
                                }
                                .font(.caption)
                                .foregroundStyle(PocketLedgerTheme.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .pocketGroupedListRow(index: 0, count: 1)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    if purchase.remainingWeightGrams > 0 {
                        Button {
                            salePurchase = purchase
                        } label: {
                            Label("Record sale", systemImage: "arrow.up.forward.circle")
                                .frame(maxWidth: .infinity)
                        }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketLedgerTheme.accent)
                        .disabled(!areBalancesRevealed || account.isArchived)
                    } else {
                        Label("Fully sold", systemImage: "checkmark.circle")
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .pocketGroupedListRow(index: 0, count: 1)
                .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .listSectionSpacing(24)
        .listSectionSeparator(.hidden)
        .textCase(nil)
        .scrollContentBackground(.hidden)
    }

    private func protectedRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            ProtectedAmountText(value: value, isRevealed: areBalancesRevealed)
                .foregroundStyle(PocketLedgerTheme.textPrimary)
                .monospacedDigit()
                .privacySensitive()
                .accessibilityLabel(areBalancesRevealed ? value : "Hidden value")
        }
        .foregroundStyle(PocketLedgerTheme.textSecondary)
    }

}

private func metalPurchaseGain(value: Money, cost: Money) -> Money? {
    let amount = (Decimal(value.minorUnits) - Decimal(cost.minorUnits)) / Decimal(value.currency.minorUnitScale)
    return try? FinanceAssetTracking.money(amount, currency: value.currency)
}

private func metalPurchaseReturnPercentage(gain: Money, cost: Money) -> Decimal? {
    guard cost.minorUnits > 0 else { return nil }
    return Decimal(gain.minorUnits) / Decimal(cost.minorUnits) * 100
}

private func signedMetalGain(_ gain: Money) -> String {
    gain.minorUnits > 0 ? "+\(gain.formatted)" : gain.formatted
}

private func assetNumber(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 4
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? String(describing: value)
}

private func assetDecimal(_ text: String) -> Decimal? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
    let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: Locale.current.decimalSeparator ?? "."))
    guard !normalized.isEmpty, normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return Decimal(string: normalized, locale: .current)
}

private func assetDecimalInput(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
        .replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
}

@MainActor
private struct MetalPurchaseEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    var onSave: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var metal: PreciousMetal = .gold
    @State private var description = ""
    @State private var date = Date()
    @State private var quantity = "1"
    @State private var weight = ""
    @State private var unit: MetalWeightUnit = .grams
    @State private var purity = "999"
    @State private var totalCost = ""
    @State private var historical = true
    @State private var fundingID: UUID?
    @State private var reconcile = false
    @State private var errorMessage: String?

    init(store: LedgerStore, account: Account, historical: Bool = true, onSave: @escaping () -> Void = {}) {
        self.store = store
        self.account = account
        self.onSave = onSave
        _historical = State(initialValue: historical)
        _metal = State(initialValue: account.tracking?.physicalAssetSubtype?.metal ?? .gold)
    }

    private var fundingAccounts: [Account] {
        store.activeAccounts.filter { $0.id != account.id && $0.currency == account.currency && ($0.type == .cash || $0.type == .bankAccount) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase") {
                    if account.tracking?.physicalAssetSubtype?.metal == nil {
                        Picker("Metal", selection: $metal) {
                            ForEach(PreciousMetal.allCases) { Text($0.displayName).tag($0) }
                        }
                    } else {
                        LabeledContent("Metal", value: metal.displayName)
                    }
                    TextField("Description (optional)", text: $description)
                    DatePicker("Purchase date", selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("Quantity", text: $quantity).keyboardType(.decimalPad)
                    TextField("Weight per item", text: $weight).keyboardType(.decimalPad)
                    Picker("Weight unit", selection: $unit) {
                        ForEach(MetalWeightUnit.allCases) { Text($0.displayName).tag($0) }
                    }
                    CurrencyInputField("Total paid including fees", text: $totalCost, currency: account.currency)
                }
                Section("Purity") {
                    if metal == .gold {
                        Menu("Gold karat presets") {
                            Button("24K · 999") { purity = "999" }
                            Button("22K") { purity = assetDecimalInput(Decimal(22) / 24 * 1000) }
                            Button("21K · 875") { purity = "875" }
                            Button("18K · 750") { purity = "750" }
                            Button("14K") { purity = assetDecimalInput(Decimal(14) / 24 * 1000) }
                            Button("9K · 375") { purity = "375" }
                        }
                    } else {
                        Menu("Silver fineness presets") {
                            Button("999 · Fine silver") { purity = "999" }
                            Button("925 · Sterling silver") { purity = "925" }
                            Button("900 · Coin silver") { purity = "900" }
                            Button("800") { purity = "800" }
                        }
                    }
                    TextField("Fineness out of 1,000", text: $purity).keyboardType(.decimalPad)
                    Text("Pure metal weight is total weight multiplied by fineness / 1,000. For example, 18K gold has fineness 750.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Section("Funding") {
                    Toggle("Historical holding", isOn: $historical)
                    if historical {
                        Text("Records an existing holding without charging another account.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    } else {
                        Picker("Paid from", selection: $fundingID) {
                            Text("Choose account").tag(Optional<UUID>.none)
                            ForEach(fundingAccounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text("Only active cash and bank accounts in \(account.currency.rawValue) are available.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                    if account.tracking?.metalPurchases.isEmpty != false {
                        Toggle("Reconcile recorded balance to tracked cost", isOn: $reconcile)
                        Text("Setup replaces this physical account's recorded balance with tracked purchase cost, avoiding double counting. Add all existing holdings before relying on totals.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("Add \(metal.displayName.lowercased()) purchase").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Purchase not saved", message: $errorMessage)
        }
    }

    private func save() {
        guard let quantity = assetDecimal(quantity), quantity > 0,
              let weight = assetDecimal(weight), weight > 0,
              let fineness = assetDecimal(purity), fineness > 0, fineness <= 1000,
              let cost = Money.parse(totalCost, currency: account.currency), cost.minorUnits > 0,
              date <= Date() else {
            errorMessage = "Enter positive quantity, weight and cost, fineness up to 1,000, and a purchase date that is not in the future."
            return
        }
        guard historical || fundingID != nil else {
            errorMessage = "Choose the account used to pay for this purchase."
            return
        }
        let purchase = MetalPurchase(metal: metal, description: description.trimmingCharacters(in: .whitespacesAndNewlines), date: date, quantity: quantity, weightPerItem: weight, unit: unit, purity: fineness / 1000, totalCost: cost)
        if store.addMetalPurchase(accountID: account.id, purchase: purchase, fundingAccountID: historical ? nil : fundingID, reconcileOpeningBalance: reconcile) {
            onSave()
            dismiss()
        } else {
            errorMessage = store.lastActionStatus ?? "Purchase could not be saved."
        }
    }
}

@MainActor
private struct MetalSaleEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let purchase: MetalPurchase
    @Environment(\.dismiss) private var dismiss
    @State private var weight = ""
    @State private var unit: MetalWeightUnit = .grams
    @State private var sellAll = false
    @State private var proceeds = ""
    @State private var date = Date()
    @State private var destinationID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sale") {
                    Text("Remaining: \(assetNumber(purchase.remainingWeightGrams)) g")
                    Toggle("Sell all remaining", isOn: $sellAll)
                    if !sellAll {
                        TextField("Weight sold", text: $weight).keyboardType(.decimalPad)
                        Picker("Weight unit", selection: $unit) {
                            ForEach(MetalWeightUnit.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    CurrencyInputField("Actual net proceeds", text: $proceeds, currency: account.currency)
                    DatePicker("Sale date", selection: $date, in: ...Date(), displayedComponents: .date)
                    Picker("Receive in", selection: $destinationID) {
                        Text("Choose account").tag(Optional<UUID>.none)
                        ForEach(store.activeAccounts.filter { $0.id != account.id && $0.currency == account.currency && ($0.type == .cash || $0.type == .bankAccount) }) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }
                    Text("Purchase cost is allocated in proportion to weight sold. Proceeds return principal and record the realized gain or loss.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            .pocketListSurface()
            .navigationTitle("Record metal sale").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Sale not saved", message: $errorMessage)
        }
    }

    private func save() {
        let weightGrams = sellAll ? purchase.remainingWeightGrams : assetDecimal(weight).map { $0 * unit.gramsPerUnit }
        guard let weightGrams, weightGrams > 0,
              let proceeds = Money.parse(proceeds, currency: account.currency), proceeds.minorUnits >= 0,
              let destinationID, date <= Date(),
              Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: purchase.date) else {
            errorMessage = "Enter a positive weight, valid proceeds, a receiving account, and a sale date between purchase and today."
            return
        }
        if store.sellMetal(accountID: account.id, purchaseID: purchase.id, weightGrams: weightGrams, proceeds: proceeds, date: date, destinationAccountID: destinationID) {
            dismiss()
        } else {
            errorMessage = store.lastActionStatus ?? "Sale could not be saved."
        }
    }
}

@MainActor
private struct MetalPricingEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let metal: PreciousMetal
    @Environment(\.dismiss) private var dismiss
    @State private var manual: Bool
    @State private var automaticPricingConsent: Bool
    @State private var showAutomaticConsent = false
    @State private var price: String
    @State private var unit: MetalWeightUnit = .grams
    @State private var asOf: Date
    @State private var errorMessage: String?

    init(store: LedgerStore, account: Account, metal: PreciousMetal) {
        self.store = store
        self.account = account
        self.metal = metal
        // One-time draft state; edits remain local until Save.
        let setting = account.tracking?.metalPricing.first { $0.metal == metal }
        let automaticEnabled = setting?.isAutomaticEnabled == true
        _manual = State(initialValue: !automaticEnabled)
        _automaticPricingConsent = State(initialValue: automaticEnabled)
        _price = State(initialValue: setting?.manualPricePerGram.map(assetDecimalInput) ?? "")
        _asOf = State(initialValue: setting?.asOf ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Automatic quote privacy") {
                    Text("Automatic price retrieval is off by default and requires an opt-in for this account and metal. If enabled, Pocket Ledger requests a USD quote from Gold API for the selected metal symbol (XAU or XAG); the network request exposes your IP address.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    Text("Gold API says it may collect API requests, timestamps, IP addresses, and approximate location inferred from IP for service delivery and improvement, usage analysis, fraud prevention, and tax or legal compliance. It says it retains information while needed to provide the service or comply with law, but does not specify a retention period for API request logs. Pocket Ledger does not send account names, holdings, balances, or transactions. Another account using Automatic may still request a shared quote.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    Link("Gold API privacy policy", destination: URL(string: "https://gold-api.com/privacy")!)
                        .font(.footnote)
                }
                Section("Pricing") {
                    Picker("Mode", selection: Binding(
                        get: { manual },
                        set: { selectedManual in
                            if selectedManual {
                                manual = true
                                automaticPricingConsent = false
                            } else if !automaticPricingConsent {
                                showAutomaticConsent = true
                            } else {
                                manual = false
                            }
                        }
                    )) {
                        Text("Automatic").tag(false)
                        Text("Manual").tag(true)
                    }
                    .alert("Enable automatic metal pricing?", isPresented: $showAutomaticConsent) {
                        Button("Enable Automatic") {
                            manual = false
                            automaticPricingConsent = true
                        }
                        Button("Keep Manual", role: .cancel) {}
                    } message: {
                        Text("The metal symbol and USD quote request go to Gold API, which receives your IP address. It may retain request details, timestamps, IP address, and approximate location for service, usage analysis, fraud prevention, and tax or legal compliance. Your account details and holdings are not sent.")
                    }
                    if manual {
                        TextField("Pure metal price (\(account.currency.rawValue))", text: $price).keyboardType(.decimalPad)
                        Picker("Price per", selection: $unit) {
                            ForEach(MetalWeightUnit.allCases) { Text($0.displayName).tag($0) }
                        }
                        DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        Text("Enter the price of pure metal. Each holding's weight is adjusted for purity automatically.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    } else {
                        Text("Gold API provides USD quotes per troy ounce. Your existing exchange rates convert the quote to \(account.currency.rawValue). Quotes refresh on opening after 15 minutes; unavailable rates require manual pricing.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
                if manual {
                    Section("Manual pricing") {
                        Text("The entered price applies to this account. Save with no price to stop automatic requests for this account; another opted-in account may still request a shared quote.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("\(metal.displayName) pricing").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Price not saved", message: $errorMessage)
            .onChange(of: unit) { oldUnit, newUnit in
                if let entered = assetDecimal(price) {
                    price = assetDecimalInput(entered / oldUnit.gramsPerUnit * newUnit.gramsPerUnit)
                }
            }
        }
    }

    private func save() {
        let enteredPrice = assetDecimal(price)
        let priceIsBlank = price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !manual || priceIsBlank || (enteredPrice.map { $0 > 0 } == true && asOf <= Date()) else {
            errorMessage = "Enter a positive pure metal price and an as-of date that is not in the future."
            return
        }
        let setting = MetalPriceSetting(
            metal: metal,
            mode: manual ? .manual : .automatic,
            manualPricePerGram: manual ? enteredPrice.map { $0 / unit.gramsPerUnit } : nil,
            asOf: manual && enteredPrice != nil ? asOf : nil,
            automaticPricingConsent: manual ? nil : automaticPricingConsent
        )
        if store.setMetalPricing(accountID: account.id, setting: setting) { dismiss() }
        else { errorMessage = store.lastActionStatus ?? "Pricing could not be saved." }
    }
}

@MainActor
private struct OtherAssetSaleEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var sharePercent = "100"
    @State private var proceeds = ""
    @State private var date = Date()
    @State private var destinationID: UUID?
    @State private var errorMessage: String?

    private var share: Decimal? {
        guard let value = assetDecimal(sharePercent), value > 0, value <= 100 else { return nil }
        return value
    }

    private var costBasis: Money? {
        guard let share else { return nil }
        let balance = store.balance(for: account)
        if share == 100 { return balance }
        return try? FinanceAssetTracking.money(
            Decimal(balance.minorUnits) * share / 100 / Decimal(account.currency.minorUnitScale),
            currency: account.currency
        )
    }

    private var estimatedGainLoss: Money? {
        guard let proceeds = Money.parse(proceeds, currency: account.currency),
              let costBasis else { return nil }
        let difference = proceeds.minorUnits.subtractingReportingOverflow(costBasis.minorUnits)
        guard !difference.overflow else { return nil }
        return Money(currency: account.currency, minorUnits: difference.partialValue)
    }

    private var receiveAccounts: [Account] {
        store.activeAccounts.filter {
            $0.id != account.id && $0.currency == account.currency && ($0.type == .cash || $0.type == .bankAccount)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sale") {
                    LabeledContent("Current estimated value") {
                        ProtectedAmountText(value: store.valuation(for: account).formatted, isRevealed: true)
                            .monospacedDigit()
                    }
                    TextField("Percent of remaining asset", text: $sharePercent)
                        .keyboardType(.decimalPad)
                    if let costBasis {
                        LabeledContent("Allocated cost basis", value: costBasis.formatted)
                    }
                    CurrencyInputField("Actual net proceeds", text: $proceeds, currency: account.currency)
                    if let estimatedGainLoss {
                        LabeledContent(
                            "Realized gain/loss",
                            value: estimatedGainLoss.minorUnits > 0 ? "+\(estimatedGainLoss.formatted)" : estimatedGainLoss.formatted
                        )
                    }
                    if let latestEntryDate = account.tracking?.investmentEntries.last?.date {
                        DatePicker("Sale date", selection: $date, in: latestEntryDate...Date(), displayedComponents: .date)
                    } else {
                        DatePicker("Sale date", selection: $date, in: ...Date(), displayedComponents: .date)
                    }
                    Picker("Receive in", selection: $destinationID) {
                        Text("Choose account").tag(Optional<UUID>.none)
                        ForEach(receiveAccounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("The percentage applies to the remaining holding. Its share of recorded cost and unrealized gain or loss is removed. Proceeds transfer to the selected account, and proceeds minus allocated cost becomes realized gain or loss.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
            .pocketListSurface()
            .navigationTitle("Sell other asset").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Sale not saved", message: $errorMessage)
        }
    }

    private func save() {
        guard let share, let proceeds = Money.parse(proceeds, currency: account.currency),
              proceeds.minorUnits > 0, let destinationID, date <= Date() else {
            errorMessage = "Enter a valid share and net proceeds, choose a receiving account, and use a sale date that is not in the future."
            return
        }
        if store.sellOtherAsset(accountID: account.id, sharePercent: share, proceeds: proceeds, date: date, destinationAccountID: destinationID) {
            dismiss()
        } else {
            errorMessage = store.lastActionStatus ?? "Sale could not be saved."
        }
    }
}

@MainActor
private struct InvestmentEntryEditor: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let realizing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var loss = false
    @State private var date = Date()
    @State private var confirmedBalance = false
    @State private var errorMessage: String?

    init(store: LedgerStore, account: Account, realizing: Bool) {
        _store = ObservedObject(wrappedValue: store)
        self.account = account
        self.realizing = realizing
        if !realizing, account.type == .physicalAsset, account.tracking?.physicalAssetSubtype == .other {
            _amount = State(initialValue: account.currency.formattedInput(minorUnits: store.valuation(for: account).minorUnits))
        }
    }

    private var unrealized: Int64 { account.tracking?.unrealizedMinorUnits ?? 0 }
    private var isOtherAsset: Bool { account.type == .physicalAsset && account.tracking?.physicalAssetSubtype == .other }
    private var recordedBalance: Money { store.balance(for: account) }
    private var proposedUnrealized: Money? {
        guard isOtherAsset, let value = Money.parse(amount, currency: account.currency), value.minorUnits >= 0 else { return nil }
        let difference = value.minorUnits.subtractingReportingOverflow(recordedBalance.minorUnits)
        guard !difference.overflow else { return nil }
        return Money(currency: account.currency, minorUnits: difference.partialValue)
    }
    private var needsBalanceConfirmation: Bool {
        guard !realizing else { return false }
        return isOtherAsset
            ? account.tracking?.investmentEntries.isEmpty != false
            : account.tracking?.lastValuation == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(realizing ? "Realize gain or loss" : isOtherAsset ? "Set estimated value" : "Replace unrealized valuation") {
                    if !realizing && !isOtherAsset {
                        Picker("Result", selection: $loss) {
                            Text("Gain").tag(false)
                            Text("Loss").tag(true)
                        }
                    } else if realizing {
                        LabeledContent("Unrealized gain/loss", value: Money(currency: account.currency, minorUnits: unrealized).formatted)
                        Button("Realize all") {
                            amount = account.currency.formattedInput(minorUnits: abs(unrealized))
                        }
                    }
                    if isOtherAsset {
                        LabeledContent("Recorded cost", value: recordedBalance.formatted)
                        if let proposedUnrealized {
                            LabeledContent("Unrealized gain/loss", value: proposedUnrealized.formatted)
                        }
                    }
                    CurrencyInputField(
                        realizing ? "Amount to realize" : isOtherAsset ? "Current estimated value" : "New unrealized amount",
                        text: $amount,
                        currency: account.currency
                    )
                    if isOtherAsset, let latestEntryDate = account.tracking?.investmentEntries.last?.date {
                        DatePicker("Effective date", selection: $date, in: latestEntryDate...Date(), displayedComponents: .date)
                    } else {
                        DatePicker("Effective date", selection: $date, in: ...Date(), displayedComponents: .date)
                    }
                    Text(realizing
                         ? "Moves this amount from unrealized performance into the recorded balance. Total value stays the same; the last valuation date stays unchanged."
                         : isOtherAsset
                            ? "Enter the asset's total estimated value. Unrealized gain or loss is calculated against its remaining recorded cost."
                            : "Replaces the previous unrealized amount. Enter zero to clear it. This does not change the recorded balance.")
                        .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    if needsBalanceConfirmation {
                        if !isOtherAsset { LabeledContent("Recorded balance", value: recordedBalance.formatted) }
                        Toggle(isOtherAsset ? "Recorded value is cost basis only" : "Recorded balance excludes this unrealized amount", isOn: $confirmedBalance)
                        Text(isOtherAsset
                             ? "Confirm this amount is the original cost, not a current market estimate. That keeps unrealized gains and losses from being counted twice."
                             : "If your recorded balance already contains this gain or loss, correct it before adding unrealized performance to avoid double counting.")
                            .font(.footnote).foregroundStyle(PocketLedgerTheme.textSecondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle(realizing ? (unrealized < 0 ? "Realize loss" : "Realize gain") : isOtherAsset ? "Update asset value" : "Update unrealized gain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: isOtherAsset ? "Asset value not saved" : "Investment activity not saved", message: $errorMessage)
        }
    }

    private func save() {
        guard let parsed = Money.parse(amount, currency: account.currency), parsed.minorUnits >= 0, date <= Date() else {
            errorMessage = "Enter a valid nonnegative amount and a date that is not in the future."
            return
        }
        let money: Money
        if isOtherAsset && !realizing {
            let difference = parsed.minorUnits.subtractingReportingOverflow(recordedBalance.minorUnits)
            guard !difference.overflow else {
                errorMessage = "The estimated value is too large."
                return
            }
            money = Money(currency: account.currency, minorUnits: difference.partialValue)
        } else {
            let negative = realizing ? unrealized < 0 : loss
            money = Money(currency: account.currency, minorUnits: negative ? -parsed.minorUnits : parsed.minorUnits)
        }
        let saved = realizing
            ? store.realizeInvestment(accountID: account.id, amount: money, date: date)
            : store.updateInvestmentValuation(accountID: account.id, amount: money, date: date, confirmRecordedBalance: confirmedBalance)
        if saved { dismiss() }
        else { errorMessage = store.lastActionStatus ?? "Investment activity could not be saved." }
    }
}
