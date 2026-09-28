import Foundation

enum DashboardWidget: String, CaseIterable, Codable, Hashable, Identifiable {
    case balance
    case attention
    case accounts
    case loans
    case monthSummary
    case recentActivity
    case upcoming
    case cashFlow
    case budgetPulse
    case storageStatus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balance:
            return "Included balances"
        case .attention:
            return "Needs attention"
        case .accounts:
            return "Accounts"
        case .loans:
            return "Loans"
        case .monthSummary:
            return "This month"
        case .recentActivity:
            return "Recent activity"
        case .upcoming:
            return "Upcoming"
        case .cashFlow:
            return "Projected cash flow"
        case .budgetPulse:
            return "Budget pulse"
        case .storageStatus:
            return "Storage status"
        }
    }

    var subtitle: String {
        switch self {
        case .balance:
            return "Balances across your currencies"
        case .attention:
            return "Items that need a review"
        case .accounts:
            return "A quick view of account balances"
        case .loans:
            return "Money lent, borrowed, and due"
        case .monthSummary:
            return "Current month spending activity"
        case .recentActivity:
            return "Your latest ledger entries"
        case .upcoming:
            return "Bills and recurring entries"
        case .cashFlow:
            return "The next 30 days"
        case .budgetPulse:
            return "Progress against this month’s budgets"
        case .storageStatus:
            return "Local and shared storage health"
        }
    }

    var systemImage: String {
        switch self {
        case .balance:
            return "wallet.pass.fill"
        case .attention:
            return "exclamationmark.triangle.fill"
        case .accounts:
            return "building.columns.fill"
        case .loans:
            return "arrow.left.arrow.right.circle.fill"
        case .monthSummary:
            return "chart.bar.xaxis"
        case .recentActivity:
            return "clock.arrow.circlepath"
        case .upcoming:
            return "calendar.badge.clock"
        case .cashFlow:
            return "chart.line.uptrend.xyaxis"
        case .budgetPulse:
            return "chart.bar.doc.horizontal"
        case .storageStatus:
            return "internaldrive.fill"
        }
    }
}

struct DashboardPreferences: Codable, Equatable {
    static let storageKey = "pocketLedger.dashboardPreferences"

    private(set) var order: [DashboardWidget]
    private(set) var disabledWidgets: Set<DashboardWidget>

    var enabledWidgets: [DashboardWidget] {
        order.filter { !disabledWidgets.contains($0) }
    }

    static let defaultPreferences = DashboardPreferences(
        order: [
            .balance,
            .attention,
            .monthSummary,
            .recentActivity,
            .accounts,
            .loans,
            .upcoming,
            .cashFlow,
            .budgetPulse,
            .storageStatus
        ],
        disabledWidgets: [
            .accounts,
            .upcoming,
            .cashFlow,
            .budgetPulse,
            .storageStatus
        ]
    )

    init(
        order: [DashboardWidget] = DashboardWidget.allCases,
        disabledWidgets: Set<DashboardWidget> = []
    ) {
        var seen = Set<DashboardWidget>()
        let orderedKnownWidgets = order.filter { seen.insert($0).inserted }
        let missingWidgets = DashboardWidget.allCases.filter { !seen.contains($0) }

        self.order = orderedKnownWidgets + missingWidgets
        self.disabledWidgets = disabledWidgets.intersection(Set(DashboardWidget.allCases))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            order: try container.decodeIfPresent([DashboardWidget].self, forKey: .order)
                ?? DashboardWidget.allCases,
            disabledWidgets: try container.decodeIfPresent(Set<DashboardWidget>.self, forKey: .disabledWidgets)
                ?? []
        )
    }

    mutating func setEnabled(_ isEnabled: Bool, for widget: DashboardWidget) {
        if isEnabled {
            disabledWidgets.remove(widget)
        } else {
            disabledWidgets.insert(widget)
        }
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }

    mutating func reset() {
        self = Self.defaultPreferences
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else {
            return .defaultPreferences
        }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private enum CodingKeys: String, CodingKey {
        case order
        case disabledWidgets
    }
}
