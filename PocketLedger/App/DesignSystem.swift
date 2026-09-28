import SwiftUI
import UIKit

enum PocketLedgerAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

// Keep palette definitions extensible; only the selected brand palette is used by the app.
enum PocketLedgerColorTheme: String, CaseIterable, Identifiable {
    case ledger
    case clay
    case ocean
    case forest
    case sunset
    case violet

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var subtitle: String {
        switch self {
        case .ledger:
            return "Warm parchment and evergreen"
        case .clay:
            return "Warm parchment and terracotta"
        case .ocean:
            return "Teal and navy"
        case .forest:
            return "Fresh emerald"
        case .sunset:
            return "Warm coral"
        case .violet:
            return "Calm purple"
        }
    }

    var systemImage: String {
        switch self {
        case .ledger:
            return "book.closed.fill"
        case .clay:
            return "flame.fill"
        case .ocean:
            return "water.waves"
        case .forest:
            return "leaf.fill"
        case .sunset:
            return "sunset.fill"
        case .violet:
            return "sparkles"
        }
    }

    var previewColors: [Color] {
        let palette = palette
        return [palette.accent, palette.surfaceElevated, palette.background]
    }

    fileprivate var palette: PocketLedgerPalette {
        switch self {
        case .clay:
            return PocketLedgerPalette(
                background: adaptiveColor(light: 0xF6EFE5, dark: 0x1B1714),
                surface: adaptiveColor(light: 0xFFFBF6, dark: 0x29211C),
                surfaceElevated: adaptiveColor(light: 0xEDE1D4, dark: 0x392B23),
                divider: adaptiveColor(light: 0x50372A, dark: 0xFFFFFF).opacity(0.11),
                textPrimary: adaptiveColor(light: 0x312720, dark: 0xFFFFFF).opacity(0.94),
                textSecondary: adaptiveColor(light: 0x725C51, dark: 0xFFFFFF).opacity(0.62),
                textTertiary: adaptiveColor(light: 0x927A6E, dark: 0xFFFFFF).opacity(0.40),
                accent: adaptiveColor(light: 0xA35438, dark: 0xE49A78),
                income: adaptiveColor(light: 0x1C6FAE, dark: 0x86B8FF),
                positive: adaptiveColor(light: 0x2E8B57, dark: 0x9EDC83),
                warning: adaptiveColor(light: 0xB06A00, dark: 0xFFD079)
            )
        case .ledger:
            return PocketLedgerPalette(
                background: adaptiveColor(light: 0xF5F0E6, dark: 0x111A15),
                surface: adaptiveColor(light: 0xFFFCF7, dark: 0x1A251E),
                surfaceElevated: adaptiveColor(light: 0xECE4D6, dark: 0x26352B),
                divider: adaptiveColor(light: 0x514737, dark: 0xFFFFFF).opacity(0.11),
                textPrimary: adaptiveColor(light: 0x273029, dark: 0xFFFFFF).opacity(0.94),
                textSecondary: adaptiveColor(light: 0x5C675D, dark: 0xFFFFFF).opacity(0.62),
                textTertiary: adaptiveColor(light: 0x818A7D, dark: 0xFFFFFF).opacity(0.40),
                accent: adaptiveColor(light: 0x356B52, dark: 0x7CC69B),
                income: adaptiveColor(light: 0x1D6FA8, dark: 0x71B3EE),
                positive: adaptiveColor(light: 0x247A47, dark: 0x6DD08D),
                warning: adaptiveColor(light: 0xA86615, dark: 0xE8B55C)
            )
        case .ocean:
            return PocketLedgerPalette(
                background: adaptiveColor(light: 0xF2F7FB, dark: 0x0A1522),
                surface: adaptiveColor(light: 0xFFFFFF, dark: 0x122235),
                surfaceElevated: adaptiveColor(light: 0xE4EEF7, dark: 0x1A3046),
                divider: adaptiveColor(light: 0x102030, dark: 0xFFFFFF).opacity(0.11),
                textPrimary: adaptiveColor(light: 0x102030, dark: 0xFFFFFF).opacity(0.94),
                textSecondary: adaptiveColor(light: 0x4D6072, dark: 0xFFFFFF).opacity(0.62),
                textTertiary: adaptiveColor(light: 0x758797, dark: 0xFFFFFF).opacity(0.40),
                accent: adaptiveColor(light: 0x087F75, dark: 0x33C7B3),
                income: adaptiveColor(light: 0x1769B0, dark: 0x5EA8FF),
                positive: adaptiveColor(light: 0x16844A, dark: 0x4DD495),
                warning: adaptiveColor(light: 0xAD6900, dark: 0xF5B24E)
            )
        case .forest:
            return PocketLedgerPalette(
                background: adaptiveColor(light: 0xF3F8F4, dark: 0x08150F),
                surface: adaptiveColor(light: 0xFFFFFF, dark: 0x10251C),
                surfaceElevated: adaptiveColor(light: 0xE5F2E9, dark: 0x19372A),
                divider: adaptiveColor(light: 0x173D28, dark: 0xFFFFFF).opacity(0.11),
                textPrimary: adaptiveColor(light: 0x163022, dark: 0xFFFFFF).opacity(0.94),
                textSecondary: adaptiveColor(light: 0x4C6757, dark: 0xFFFFFF).opacity(0.62),
                textTertiary: adaptiveColor(light: 0x789080, dark: 0xFFFFFF).opacity(0.40),
                accent: adaptiveColor(light: 0x237A50, dark: 0x66D48D),
                income: adaptiveColor(light: 0x1B6D9D, dark: 0x74C8FF),
                positive: adaptiveColor(light: 0x187A45, dark: 0x82E3A5),
                warning: adaptiveColor(light: 0xA36A00, dark: 0xF1C56D)
            )
        case .sunset:
            return PocketLedgerPalette(
                background: adaptiveColor(light: 0xFFF7F2, dark: 0x1A100F),
                surface: adaptiveColor(light: 0xFFFFFF, dark: 0x2A1B1A),
                surfaceElevated: adaptiveColor(light: 0xFCE7DC, dark: 0x3C2621),
                divider: adaptiveColor(light: 0x5A2B20, dark: 0xFFFFFF).opacity(0.11),
                textPrimary: adaptiveColor(light: 0x3A211B, dark: 0xFFFFFF).opacity(0.94),
                textSecondary: adaptiveColor(light: 0x76564C, dark: 0xFFFFFF).opacity(0.62),
                textTertiary: adaptiveColor(light: 0xA17E72, dark: 0xFFFFFF).opacity(0.40),
                accent: adaptiveColor(light: 0xC45C32, dark: 0xFF9F6E),
                income: adaptiveColor(light: 0x1C6FAE, dark: 0x86B8FF),
                positive: adaptiveColor(light: 0x2E8B57, dark: 0x9EDC83),
                warning: adaptiveColor(light: 0xB06A00, dark: 0xFFD079)
            )
        case .violet:
            return PocketLedgerPalette(
                background: adaptiveColor(light: 0xF8F5FF, dark: 0x120F1E),
                surface: adaptiveColor(light: 0xFFFFFF, dark: 0x1D1830),
                surfaceElevated: adaptiveColor(light: 0xEDE6FF, dark: 0x2B2448),
                divider: adaptiveColor(light: 0x3C2C68, dark: 0xFFFFFF).opacity(0.11),
                textPrimary: adaptiveColor(light: 0x261D40, dark: 0xFFFFFF).opacity(0.94),
                textSecondary: adaptiveColor(light: 0x62577C, dark: 0xFFFFFF).opacity(0.62),
                textTertiary: adaptiveColor(light: 0x8B81A2, dark: 0xFFFFFF).opacity(0.40),
                accent: adaptiveColor(light: 0x6B4BC1, dark: 0xB8A1FF),
                income: adaptiveColor(light: 0x3D79B8, dark: 0x8AC8FF),
                positive: adaptiveColor(light: 0x298567, dark: 0x79DFBA),
                warning: adaptiveColor(light: 0xA06A00, dark: 0xF8CD76)
            )
        }
    }
}

fileprivate struct PocketLedgerPalette {
    let background: Color
    let surface: Color
    let surfaceElevated: Color
    let divider: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let income: Color
    let positive: Color
    let warning: Color
}

fileprivate func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        let value = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    })
}

enum PocketLedgerMotion {
    static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.28)
    }

    static func expressive(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.16)
    }
}

enum PocketLedgerTheme {
    // Reserved for a future return of user-selectable palettes.
    static let colorThemeKey = "pocketLedger.colorTheme"
    static let appearanceModeKey = "pocketLedger.appearanceMode"
    static let balanceVisibilityKey = "pocketLedger.areBalancesRevealed"

    static var colorTheme: PocketLedgerColorTheme {
        .clay
    }

    static var appearanceMode: PocketLedgerAppearanceMode {
        let rawValue = UserDefaults.standard.string(forKey: appearanceModeKey)
        return PocketLedgerAppearanceMode(rawValue: rawValue ?? "") ?? .system
    }

    private static var palette: PocketLedgerPalette {
        colorTheme.palette
    }

    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var surfaceElevated: Color { palette.surfaceElevated }
    static var divider: Color { Color(uiColor: .separator) }
    static var textPrimary: Color { .primary }
    static var textSecondary: Color { .secondary }
    static var textTertiary: Color { .secondary.opacity(0.85) }
    static var accent: Color { palette.accent }
    static var income: Color { palette.income }
    static var positive: Color { palette.positive }
    static var warning: Color { palette.warning }
    static var glassTint: Color { accent.opacity(0.10) }

    static let screenHorizontalPadding: CGFloat = 16
    static let contentSpacing: CGFloat = 20
    static let sectionSpacing: CGFloat = 12
    static let cardCornerRadius: CGFloat = 20
}

struct PocketIcon: View {
    let systemImage: String
    var tint: Color = PocketLedgerTheme.accent
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .pocketGlassSurface(cornerRadius: size * 0.28, tint: tint.opacity(0.12))
    }
}

struct ProtectedAmountText: View {
    let value: String
    let isRevealed: Bool

    var body: some View {
        Text(value)
            .blur(radius: isRevealed ? 0 : 8)
            .privacySensitive()
            .accessibilityLabel(isRevealed ? value : "Hidden amount")
    }
}

@MainActor
struct BalanceVisibilityControl: View {
    @ObservedObject var security: AppSecurityService
    @Binding var isRevealed: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAuthenticating = false
    @State private var isShowingBiometryUnavailable = false
    @State private var requestID: UUID?

    var body: some View {
        Button(action: toggle) {
            Label(
                isRevealed ? "Hide" : "Reveal",
                systemImage: isRevealed ? "eye.slash" : "eye"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PocketLedgerTheme.accent)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(isAuthenticating)
        .accessibilityLabel(isRevealed ? "Hide financial amounts" : "Reveal financial amounts")
        .accessibilityHint(isRevealed
            ? "Hides financial amounts across the app."
            : "Requires \(security.availableBiometry?.displayName ?? "Face ID") to reveal financial amounts across the app.")
        .alert("Biometrics unavailable", isPresented: $isShowingBiometryUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Face ID or Touch ID on this device to reveal balance amounts.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { conceal() }
        }
        .onChange(of: isRevealed) { _, revealed in
            if !revealed && isAuthenticating {
                requestID = nil
                isAuthenticating = false
            }
        }
    }

    private func toggle() {
        guard !isAuthenticating else { return }
        guard !isRevealed else {
            conceal()
            return
        }
        guard security.availableBiometry != nil else {
            isShowingBiometryUnavailable = true
            return
        }

        let requestID = UUID()
        self.requestID = requestID
        isAuthenticating = true
        Task {
            let authenticated = await security.authenticateToRevealBalances()
            guard self.requestID == requestID else { return }
            isAuthenticating = false
            isRevealed = authenticated
        }
    }

    private func conceal() {
        requestID = nil
        isAuthenticating = false
        isRevealed = false
    }
}

@MainActor
struct BalanceVisibilityToolbarItem: ToolbarContent {
    @ObservedObject var security: AppSecurityService
    @AppStorage(PocketLedgerTheme.balanceVisibilityKey) private var isRevealed = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            BalanceVisibilityControl(security: security, isRevealed: $isRevealed)
                .accessibilityIdentifier("balance-visibility-control")
        }
    }
}

@MainActor
struct PocketLedgerToolbar<Content: ToolbarContent>: ToolbarContent {
    let security: AppSecurityService
    private let content: Content

    init(
        security: AppSecurityService,
        @ToolbarContentBuilder content: () -> Content
    ) {
        self.security = security
        self.content = content()
    }

    var body: some ToolbarContent {
        BalanceVisibilityToolbarItem(security: security)
        content
    }
}

struct CurrencySelectionMenu: View {
    @Binding var currency: LedgerCurrency
    let currencies: [LedgerCurrency]

    init(currency: Binding<LedgerCurrency>, currencies: [LedgerCurrency] = LedgerCurrency.allCases) {
        _currency = currency
        self.currencies = LedgerCurrency.allCases.filter {
            currencies.contains($0) || $0 == currency.wrappedValue
        }
    }

    var body: some View {
        Menu {
            ForEach(currencies) { option in
                Button {
                    currency = option
                } label: {
                    if option == currency {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currency.rawValue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Currency")
        .accessibilityValue(Text(currency.rawValue))
    }
}

struct CurrencyInputField: View {
    private let title: String
    @Binding private var text: String
    @Binding private var currency: LedgerCurrency
    private let selectableCurrencies: [LedgerCurrency]
    private let focusOnAppear: Bool
    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        text: Binding<String>,
        currency: LedgerCurrency
    ) {
        self.title = title
        _text = text
        _currency = .constant(currency)
        selectableCurrencies = [currency]
        focusOnAppear = false
    }

    init(
        _ title: String,
        text: Binding<String>,
        currency: Binding<LedgerCurrency>,
        selectableCurrencies: [LedgerCurrency] = LedgerCurrency.allCases,
        focusOnAppear: Bool = false
    ) {
        self.title = title
        _text = text
        _currency = currency
        self.selectableCurrencies = LedgerCurrency.allCases.filter {
            selectableCurrencies.contains($0) || $0 == currency.wrappedValue
        }
        self.focusOnAppear = focusOnAppear
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .monospacedDigit()
                .focused($isFocused)

            if selectableCurrencies.count > 1 {
                CurrencySelectionMenu(currency: $currency, currencies: selectableCurrencies)
            } else {
                Text(currency.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            formatText()
            if focusOnAppear { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                formatText()
            }
        }
        .onChange(of: currency) { _, _ in
            if !isFocused {
                formatText()
            }
        }
    }

    private func formatText() {
        let formatted = currency.formattedInput(text)
        guard formatted != text else { return }
        text = formatted
    }
}

struct PocketGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct PocketSwipeActionLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    var iconColor: Color = .white
    var titleColor: Color = .white

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 48, height: 48)
                .background(tint, in: Circle())

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

struct PocketCircularSwipeAction: View {
    let title: String
    let systemImage: String
    let tint: Color
    var iconColor: Color = .white
    var titleColor: Color = .white
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            PocketSwipeActionLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                iconColor: iconColor,
                titleColor: titleColor
            )
        }
        .buttonStyle(.plain)
        .tint(tint)
        .accessibilityLabel(title)
    }
}

extension View {
    @ViewBuilder
    func pocketSwipeActionsContainer() -> some View {
        if #available(iOS 27, *) {
            self.swipeActionsContainer()
        } else {
            self
        }
    }

    func pocketScreen() -> some View {
        self
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .background {
                LinearGradient(
                    colors: [
                        PocketLedgerTheme.background,
                        PocketLedgerTheme.surfaceElevated.opacity(0.24),
                        PocketLedgerTheme.background
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .foregroundStyle(PocketLedgerTheme.textPrimary)
            .tint(PocketLedgerTheme.accent)
            .preferredColorScheme(PocketLedgerTheme.appearanceMode.preferredColorScheme)
    }

    func pocketListSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .listRowBackground(PocketLedgerTheme.surface)
            .pocketScreen()
    }

    func pocketCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .pocketGroupedSurface(cornerRadius: cornerRadius)
    }

    /// A calm, grouped content surface for information that does not need to
    /// float above the page. Interactive controls should use Liquid Glass.
    @ViewBuilder
    func pocketGroupedSurface(cornerRadius: CGFloat = PocketLedgerTheme.cardCornerRadius) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PocketLedgerTheme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(PocketLedgerTheme.divider.opacity(0.65), lineWidth: 0.75)
            }
            .shadow(
                color: Color.black.opacity(0.04),
                radius: 12,
                y: 5
            )
    }

    @ViewBuilder
    func pocketGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                self.glassEffect(
                    .regular
                        .tint(tint ?? PocketLedgerTheme.glassTint)
                        .interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                self.glassEffect(
                    .regular.tint(tint ?? PocketLedgerTheme.glassTint),
                    in: .rect(cornerRadius: cornerRadius)
                )
            }
        } else {
            self
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(PocketLedgerTheme.divider, lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func pocketGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if interactive {
                self.glassEffect(
                    .regular
                        .tint(tint ?? PocketLedgerTheme.glassTint)
                        .interactive(),
                    in: .capsule
                )
            } else {
                self.glassEffect(
                    .regular.tint(tint ?? PocketLedgerTheme.glassTint),
                    in: .capsule
                )
            }
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(PocketLedgerTheme.divider, lineWidth: 1)
                }
        }
    }
}
