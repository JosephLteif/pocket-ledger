import StoreKit
import SwiftUI

enum ProFeature: String, Identifiable, Equatable {
    case general
    case accounts
    case accountTypes
    case schedules
    case budgets
    case budgetRollover
    case netWorth
    case historicalMetrics
    case pdfReports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "More room for your finances"
        case .accounts: "Add more accounts"
        case .accountTypes: "Unlock advanced account types"
        case .schedules: "Schedule more transactions"
        case .budgets: "Create more budgets"
        case .budgetRollover: "Use budget rollover"
        case .netWorth: "Explore your net worth"
        case .historicalMetrics: "Explore older financial history"
        case .pdfReports: "Export a PDF report"
        }
    }
}

@MainActor
final class ProEntitlementStore: ObservableObject {
    static let productIdentifier = "com.josephlteif.pocketledger.pro.lifetime"
    static let shared = ProEntitlementStore()

    @Published private(set) var product: Product?
    @Published private(set) var hasProAccess = false
    @Published private(set) var hasResolvedEntitlements = false
    @Published private(set) var requestedFeature: ProFeature = .general
    @Published var message: String?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }

        Task {
            await refreshEntitlements()
            await loadProduct()
        }
    }

    func requestUpgrade(for feature: ProFeature = .general) {
        guard !hasProAccess else { return }
        requestedFeature = feature
    }

    func refreshEntitlements() async {
        var ownsPro = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productIdentifier,
                  transaction.revocationDate == nil else {
                continue
            }
            ownsPro = true
        }

        hasProAccess = ownsPro
        hasResolvedEntitlements = true
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productIdentifier]).first
        } catch {
            product = nil
        }
    }

    func purchase() async {
        guard let product else {
            message = "Pocket Ledger Pro is temporarily unavailable. Try again later."
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = "Apple could not verify this purchase. Pro was not enabled."
                    return
                }
                await transaction.finish()
                await refreshEntitlements()
            case .pending:
                message = "This purchase is pending Apple’s approval. Pro will unlock when it is approved."
            case .userCancelled:
                break
            @unknown default:
                message = "The purchase could not be completed. Try again later."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !hasProAccess {
                message = "No Pocket Ledger Pro purchase was found for this Apple Account."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

enum PocketLedgerTierPolicy {
    static let freeAccountLimit = 5
    static let freeEnabledScheduleLimit = 10
    static let freeBudgetLimit = 5

    static func accountTypeRequiresPro(_ type: AccountType) -> Bool {
        type == .investment || type == .physicalAsset
    }

    static func canCreateAccount(type: AccountType, activeCount: Int, hasPro: Bool) -> Bool {
        hasPro || (!accountTypeRequiresPro(type) && activeCount < freeAccountLimit)
    }

    static func canActivateSchedule(
        isEnabled: Bool,
        isAlreadyEnabled: Bool,
        enabledCount: Int,
        hasPro: Bool
    ) -> Bool {
        hasPro || !isEnabled || isAlreadyEnabled || enabledCount < freeEnabledScheduleLimit
    }

    static func canCreateBudget(count: Int, hasPro: Bool) -> Bool {
        hasPro || count < freeBudgetLimit
    }

    static func canUseRollover(isAlreadyEnabled: Bool, hasPro: Bool) -> Bool {
        hasPro || isAlreadyEnabled
    }

    static func canViewHistoricalPeriod(
        start: Date,
        isCalendarYear: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard let currentMonth = calendar.dateInterval(of: .month, for: now)?.start else {
            return true
        }
        if isCalendarYear {
            return calendar.component(.year, from: start) == calendar.component(.year, from: now)
        }
        guard
              let earliestMonth = calendar.date(byAdding: .month, value: -11, to: currentMonth) else {
            return true
        }
        return start >= earliestMonth && start <= currentMonth
    }
}

@MainActor
struct ProUpgradePrompt: View {
    @ObservedObject private var access = ProEntitlementStore.shared
    @State private var isPresentingUpgrade = false
    let title: String
    let detail: String
    let feature: ProFeature

    var body: some View {
        Button {
            access.requestUpgrade(for: feature)
            isPresentingUpgrade = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(PocketLedgerTheme.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(PocketLedgerTheme.textSecondary)
                Text("Explore Pro")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketLedgerTheme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .pocketGroupedSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresentingUpgrade) {
            ProUpgradeView(access: access)
        }
    }
}

@MainActor
struct ProUpgradeButton<Label: View>: View {
    @ObservedObject private var access = ProEntitlementStore.shared
    @State private var isPresentingUpgrade = false
    let feature: ProFeature
    let label: Label

    init(feature: ProFeature, @ViewBuilder label: () -> Label) {
        self.feature = feature
        self.label = label()
    }

    var body: some View {
        Button {
            access.requestUpgrade(for: feature)
            isPresentingUpgrade = true
        } label: {
            label
        }
        .sheet(isPresented: $isPresentingUpgrade) {
            ProUpgradeView(access: access)
        }
    }
}

@MainActor
struct ProUpgradeView: View {
    @ObservedObject var access: ProEntitlementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(PocketLedgerTheme.accent)
                        Text("Pocket Ledger Pro")
                            .font(.largeTitle.weight(.bold))
                        Text(access.requestedFeature.title)
                            .font(.headline)
                            .foregroundStyle(PocketLedgerTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Unlimited accounts, schedules, and budgets", systemImage: "infinity")
                        Label("Investment and physical-asset accounts", systemImage: "chart.pie")
                        Label("Net worth, rollover budgets, and older metrics", systemImage: "chart.xyaxis.line")
                        Label("Shareable PDF reports", systemImage: "doc.richtext")
                    }
                    .font(.subheadline)

                    if access.hasProAccess {
                        Label("Pro is active on this Apple Account", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(PocketLedgerTheme.positive)
                    } else if !access.hasResolvedEntitlements {
                        ProgressView("Checking Apple purchases…")
                            .frame(maxWidth: .infinity)
                    } else if let product = access.product {
                        Button {
                            Task { await access.purchase() }
                        } label: {
                            if access.isPurchasing {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Unlock Pro · \(product.displayPrice)")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PocketLedgerTheme.accent)
                        .disabled(access.isPurchasing || access.isRestoring)
                        Text("One-time purchase. No subscription.")
                            .font(.caption)
                            .foregroundStyle(PocketLedgerTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Pro purchase unavailable",
                            systemImage: "storefront",
                            description: Text("Try again later or restore an existing purchase.")
                        )
                        Button("Try Again") {
                            Task { await access.loadProduct() }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        Task { await access.restorePurchases() }
                    } label: {
                        if access.isRestoring {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Restore Purchases").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(access.isPurchasing || access.isRestoring)
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Pocket Ledger Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Purchase", isPresented: Binding(
                get: { access.message != nil },
                set: { if !$0 { access.message = nil } }
            )) {
                Button("OK") { access.message = nil }
            } message: {
                Text(access.message ?? "")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

