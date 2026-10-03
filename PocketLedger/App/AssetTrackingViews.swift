import SwiftUI

@MainActor
struct AssetTrackingSection: View {
    @ObservedObject var store: LedgerStore
    let account: Account
    let areBalancesRevealed: Bool

    @State private var sheet: AssetSheet?
    @State private var confirmingUndo = false
    @State private var confirmingDisable = false
    @State private var errorMessage: String?

    private enum AssetSheet: Identifiable {
        case purchase, pricing(PreciousMetal), investment(Bool)
        var id: String {
            switch self {
            case .purchase: "purchase"
            case .pricing(let metal): "price-\(metal.rawValue)"
            case .investment(let realizing): "investment-\(realizing)"
            }
        }
    }

    var body: some View {
        Group {
            if account.type == .physicalAsset {
                metals
            } else if account.type == .investment {
                investment
            }
            if account.tracking != nil {
                Section {
                    Button("Undo latest asset activity", role: .destructive) { confirmingUndo = true }
                        .disabled(!areBalancesRevealed)
                    Text("To correct an entry, undo the latest activity and enter it again. Linked ledger movements are reversed together.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Turn off asset tracking", role: .destructive) { confirmingDisable = true }
                        .disabled(!areBalancesRevealed)
                }
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if account.type == .physicalAsset {
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
            }
        }
        .confirmationDialog("Undo the latest asset activity?", isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("Undo activity", role: .destructive) {
                if !store.undoLatestAssetActivity(accountID: account.id) {
                    errorMessage = store.lastActionStatus ?? "Activity could not be undone."
                }
            }
        }
        .confirmationDialog("Turn off asset tracking?", isPresented: $confirmingDisable, titleVisibility: .visible) {
            Button("Turn off tracking", role: .destructive) {
                if !store.disableAssetTracking(accountID: account.id) {
                    errorMessage = store.lastActionStatus ?? "Undo existing asset history first."
                }
            }
        } message: {
            Text("Tracking history must be empty. Undo existing activity first; the recorded account balance will remain.")
        }
        .errorMessageAlert(title: "Asset activity not saved", message: $errorMessage)
        .onChange(of: areBalancesRevealed) { _, revealed in
            if !revealed { sheet = nil }
        }
        .task {
            if account.type == .physicalAsset { await store.refreshMetalPrices() }
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(areBalancesRevealed ? value : "••••")
                .monospacedDigit().privacySensitive()
                .accessibilityLabel(areBalancesRevealed ? value : "Hidden value")
        }
    }

    @ViewBuilder private var metals: some View {
        let purchases = account.tracking?.metalPurchases ?? []

        Section {
            if purchases.isEmpty {
                Text("Track gold and silver by purchase, weight and purity.")
                    .foregroundStyle(.secondary)
            } else {
                valueRow("Recorded balance", store.balance(for: account).formatted)
                valueRow("Estimated metal value", store.valuation(for: account).formatted)
            }
            Button("Add metal purchase") { sheet = .purchase }
                .disabled(!areBalancesRevealed || account.isArchived)
            if !areBalancesRevealed {
                Text("Reveal balances to view or update holdings.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Metals") } footer: {
            Text("Estimated metal value excludes jewelry workmanship and retail premiums. Missing prices use purchase cost in totals.")
        }
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
                }
            }
        }
        Section("Metal prices") {
            ForEach(PreciousMetal.allCases) { metal in
                VStack(alignment: .leading, spacing: 6) {
                    Button("\(metal.displayName) pricing") { sheet = .pricing(metal) }
                        .disabled(!areBalancesRevealed || account.isArchived || account.tracking?.metalPurchases.isEmpty != false)
                    if let price = store.metalPricePerGram(account: account, metal: metal) {
                        valueRow("Pure metal / gram", "\(assetNumber(price)) \(account.currency.rawValue)")
                    } else {
                        Text("Price needed").foregroundStyle(.secondary)
                    }
                    Text(store.metalQuoteDescription(account: account, metal: metal))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Refresh market prices") { Task { await store.refreshMetalPrices(force: true) } }
            if account.tracking?.metalPurchases.isEmpty != false {
                Text("Add a purchase to configure metal pricing.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var investment: some View {
        Section("Investment performance") {
            valueRow("Recorded balance", store.balance(for: account).formatted)
            valueRow("Unrealized gain/loss", Money(currency: account.currency, minorUnits: account.tracking?.unrealizedMinorUnits ?? 0).formatted)
            valueRow("Estimated total value", store.valuation(for: account).formatted)
            if let entry = account.tracking?.lastValuation {
                LabeledContent("Last valuation", value: entry.date.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Entered", value: entry.enteredAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("No valuation entered yet.").foregroundStyle(.secondary)
            }
            Button("Update unrealized gain/loss") { sheet = .investment(false) }
                .disabled(!areBalancesRevealed || account.isArchived)
            Button("Realize gain/loss") { sheet = .investment(true) }
                .disabled(!areBalancesRevealed || (account.tracking?.unrealizedMinorUnits ?? 0) == 0 || account.isArchived)
            Text("Gains stay in this account. Use a transfer for withdrawals. Realizing a gain or loss preserves estimated total value.")
                .font(.footnote).foregroundStyle(.secondary)
            if !areBalancesRevealed {
                Text("Reveal balances to update investment performance.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let entries = account.tracking?.investmentEntries, !entries.isEmpty {
            Section("Performance history") {
                ForEach(Array(entries.suffix(20).reversed())) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        valueRow(entry.kind == .valuation ? "Unrealized valuation" : "Realized gain/loss", entry.amount.formatted)
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Entered \(entry.enteredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if entries.count > 20 {
                    Text("Showing the latest 20 entries.").font(.footnote).foregroundStyle(.secondary)
                }
            }
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
                    Text(purchase.description.isEmpty ? "\(purchase.metal.displayName) purchase" : purchase.description)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(purchase.metal.displayName) · \(purchase.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.textTertiary)
                    .accessibilityHidden(true)
            }

            HStack(alignment: .top, spacing: 12) {
                valueMetric(
                    title: "Current value",
                    value: valuation.map { protected($0.formatted) } ?? "Price needed",
                    isProtected: valuation != nil
                )
                Spacer(minLength: 8)
                valueMetric(
                    title: purchase.sales.isEmpty ? "Purchase cost" : "Cost remaining",
                    value: protected(purchase.remainingCost.formatted),
                    trailing: true
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "scalemass")
                    .accessibilityHidden(true)
                Text(areBalancesRevealed
                     ? "\(assetNumber(purchase.remainingQuantity)) of \(assetNumber(purchase.quantity)) remaining · \(assetNumber(purchase.remainingWeightGrams)) g"
                     : "••••")
                    .accessibilityLabel(areBalancesRevealed
                        ? "\(assetNumber(purchase.remainingQuantity)) of \(assetNumber(purchase.quantity)) remaining, \(assetNumber(purchase.remainingWeightGrams)) grams"
                        : "Hidden holding quantities")
                Spacer(minLength: 0)
                if let gain {
                    Text(areBalancesRevealed ? signedMetalGain(gain) : "••••")
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
        VStack(alignment: alignment, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(PocketLedgerTheme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(2)
                .privacySensitive()
                .accessibilityLabel(areBalancesRevealed || !isProtected ? value : "Hidden amount")
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private func protected(_ value: String) -> String {
        areBalancesRevealed ? value : "••••"
    }
}

@MainActor
private struct MetalPurchaseDetailView: View {
    @ObservedObject var store: LedgerStore
    let accountID: UUID
    let purchaseID: UUID

    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var areBalancesRevealed = false
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

            Section("Purchase details") {
                LabeledContent("Metal", value: purchase.metal.displayName)
                if !purchase.description.isEmpty {
                    LabeledContent("Description", value: purchase.description)
                }
                LabeledContent("Purchase date", value: purchase.date.formatted(date: .long, time: .omitted))
                protectedRow("Quantity purchased", assetNumber(purchase.quantity))
                protectedRow("Weight per item", "\(assetNumber(purchase.weightPerItem)) \(purchase.unit.displayName.lowercased())")
                protectedRow("Total weight purchased", "\(assetNumber(purchase.weightGrams)) g")
                protectedRow("Purity", "\(assetNumber(purchase.purity * 100))%")
                protectedRow("Pure-metal weight at purchase", "\(assetNumber(purchase.weightGrams * purchase.purity)) g")
                protectedRow("Total paid including fees", purchase.totalCost.formatted)
            }

            Section("Remaining holding") {
                protectedRow("Quantity remaining", assetNumber(purchase.remainingQuantity))
                protectedRow("Weight remaining", "\(assetNumber(purchase.remainingWeightGrams)) g")
                protectedRow("Pure-metal weight remaining", "\(assetNumber(purchase.pureWeightGrams)) g")
                protectedRow("Purchase cost remaining", purchase.remainingCost.formatted)
            }

            Section("Sales") {
                if purchase.sales.isEmpty {
                    Text("No sales recorded for this purchase.")
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                } else {
                    ForEach(purchase.sales) { sale in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(sale.date.formatted(date: .abbreviated, time: .omitted))
                                Spacer()
                                Text(sensitive(sale.proceeds.formatted))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .privacySensitive()
                                    .accessibilityLabel(areBalancesRevealed ? sale.proceeds.formatted : "Hidden value")
                            }
                            HStack {
                                Text(sensitive("\(assetNumber(sale.weightGrams)) g sold"))
                                    .privacySensitive()
                                    .accessibilityLabel(areBalancesRevealed
                                        ? "\(assetNumber(sale.weightGrams)) grams sold"
                                        : "Hidden sale weight")
                                Spacer()
                                Text("Realized \(sensitive(signedMetalGain(sale.gain)))")
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

            Section {
                if purchase.remainingWeightGrams > 0 {
                    Button {
                        salePurchase = purchase
                    } label: {
                        Label("Record sale", systemImage: "arrow.up.forward.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!areBalancesRevealed || account.isArchived)
                } else {
                    Label("Fully sold", systemImage: "checkmark.circle")
                        .foregroundStyle(PocketLedgerTheme.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func protectedRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(sensitive(value))
                .monospacedDigit()
                .privacySensitive()
                .accessibilityLabel(areBalancesRevealed ? value : "Hidden value")
        }
    }

    private func sensitive(_ value: String) -> String {
        areBalancesRevealed ? value : "••••"
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

    private var fundingAccounts: [Account] {
        store.activeAccounts.filter { $0.id != account.id && $0.currency == account.currency && ($0.type == .cash || $0.type == .bankAccount) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase") {
                    Picker("Metal", selection: $metal) {
                        ForEach(PreciousMetal.allCases) { Text($0.displayName).tag($0) }
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
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Funding") {
                    Toggle("Historical holding", isOn: $historical)
                    if historical {
                        Text("Records an existing holding without charging another account.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Paid from", selection: $fundingID) {
                            Text("Choose account").tag(Optional<UUID>.none)
                            ForEach(fundingAccounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text("Only active cash and bank accounts in \(account.currency.rawValue) are available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if account.tracking?.metalPurchases.isEmpty != false {
                        Toggle("Reconcile recorded balance to tracked cost", isOn: $reconcile)
                        Text("Setup replaces this physical account's recorded balance with tracked purchase cost, avoiding double counting. Add all existing holdings before relying on totals.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("Add metal purchase").navigationBarTitleDisplayMode(.inline)
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
                        .font(.footnote).foregroundStyle(.secondary)
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
        _manual = State(initialValue: setting?.mode == .manual)
        _price = State(initialValue: setting?.manualPricePerGram.map(assetDecimalInput) ?? "")
        _asOf = State(initialValue: setting?.asOf ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pricing") {
                    Picker("Mode", selection: $manual) {
                        Text("Automatic").tag(false)
                        Text("Manual").tag(true)
                    }
                    if manual {
                        TextField("Pure metal price (\(account.currency.rawValue))", text: $price).keyboardType(.decimalPad)
                        Picker("Price per", selection: $unit) {
                            ForEach(MetalWeightUnit.allCases) { Text($0.displayName).tag($0) }
                        }
                        DatePicker("As of", selection: $asOf, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        Text("Enter the price of pure metal. Each holding's weight is adjusted for purity automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Gold API provides USD quotes per troy ounce. Your existing exchange rates convert the quote to \(account.currency.rawValue). Quotes refresh on opening after 15 minutes; unavailable rates require manual pricing.")
                            .font(.footnote).foregroundStyle(.secondary)
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
        guard !manual || (enteredPrice.map { $0 > 0 } == true && asOf <= Date()) else {
            errorMessage = "Enter a positive pure metal price and an as-of date that is not in the future."
            return
        }
        let setting = MetalPriceSetting(metal: metal, mode: manual ? .manual : .automatic, manualPricePerGram: manual ? enteredPrice.map { $0 / unit.gramsPerUnit } : nil, asOf: manual ? asOf : nil)
        if store.setMetalPricing(accountID: account.id, setting: setting) { dismiss() }
        else { errorMessage = store.lastActionStatus ?? "Pricing could not be saved." }
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

    private var unrealized: Int64 { account.tracking?.unrealizedMinorUnits ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section(realizing ? "Realize gain or loss" : "Replace unrealized valuation") {
                    if !realizing {
                        Picker("Result", selection: $loss) {
                            Text("Gain").tag(false)
                            Text("Loss").tag(true)
                        }
                    } else {
                        LabeledContent("Unrealized gain/loss", value: Money(currency: account.currency, minorUnits: unrealized).formatted)
                        Button("Realize all") {
                            amount = account.currency.formattedInput(minorUnits: abs(unrealized))
                        }
                    }
                    CurrencyInputField(realizing ? "Amount to realize" : "New unrealized amount", text: $amount, currency: account.currency)
                    DatePicker("Effective date", selection: $date, in: ...Date(), displayedComponents: .date)
                    Text(realizing
                         ? "Moves this amount from unrealized performance into the recorded balance. Total value stays the same; the last valuation date stays unchanged."
                         : "Replaces the previous unrealized amount. Enter zero to clear it. This does not change the recorded balance.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !realizing && account.tracking?.lastValuation == nil {
                        LabeledContent("Recorded balance", value: store.balance(for: account).formatted)
                        Toggle("Recorded balance excludes this unrealized amount", isOn: $confirmedBalance)
                        Text("If your recorded balance already contains this gain or loss, correct it before adding unrealized performance to avoid double counting.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle(realizing ? (unrealized < 0 ? "Realize loss" : "Realize gain") : "Update unrealized gain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .errorMessageAlert(title: "Investment activity not saved", message: $errorMessage)
        }
    }

    private func save() {
        guard let parsed = Money.parse(amount, currency: account.currency), parsed.minorUnits >= 0, date <= Date() else {
            errorMessage = "Enter a valid nonnegative amount and a date that is not in the future."
            return
        }
        let negative = realizing ? unrealized < 0 : loss
        let money = Money(currency: account.currency, minorUnits: negative ? -parsed.minorUnits : parsed.minorUnits)
        let saved = realizing
            ? store.realizeInvestment(accountID: account.id, amount: money, date: date)
            : store.updateInvestmentValuation(accountID: account.id, amount: money, date: date, confirmRecordedBalance: confirmedBalance)
        if saved { dismiss() }
        else { errorMessage = store.lastActionStatus ?? "Investment activity could not be saved." }
    }
}
