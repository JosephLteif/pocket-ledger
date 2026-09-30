import SwiftUI

private enum PasscodeSheet: Identifiable, Equatable {
    case set
    case change

    var id: String {
        switch self {
        case .set:
            return "set"
        case .change:
            return "change"
        }
    }

    var title: String {
        switch self {
        case .set:
            return "Set app passcode"
        case .change:
            return "Change app passcode"
        }
    }
}

@MainActor
struct SecuritySettingsView: View {
    @ObservedObject var store: LedgerStore
    @ObservedObject var security: AppSecurityService
    @State private var passcodeSheet: PasscodeSheet?
    @State private var isShowingRemoveConfirmation = false
    @State private var isUpdatingBiometrics = false
    @State private var errorMessage: String?
    @State private var dailyReminderStatus: String?
    @State private var isUpdatingDailyReminder = false
    @State private var budgetAlertStatus: String?
    @State private var isUpdatingBudgetAlerts = false
    @AppStorage(PocketLedgerTheme.appearanceModeKey) private var selectedAppearanceMode = PocketLedgerAppearanceMode.system.rawValue
    @AppStorage(NotificationService.dailyTransactionReminderEnabledKey)
    private var isDailyTransactionReminderEnabled = false
    @AppStorage(NotificationService.dailyTransactionReminderMinutesKey)
    private var dailyTransactionReminderMinutes = NotificationService.dailyTransactionReminderDefaultMinutes
    @AppStorage(NotificationService.scheduledLiveActivityEnabledKey)
    private var isScheduledLiveActivityEnabled = false
    @AppStorage(NotificationService.budgetThresholdAlertsEnabledKey)
    private var areBudgetThresholdAlertsEnabled = false

    var body: some View {
        Form {
                Section("Appearance") {
                    Picker("Mode", selection: $selectedAppearanceMode) {
                        ForEach(PocketLedgerAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Choose whether Pocket Ledger follows your device appearance or stays light or dark.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Reminders") {
                    Toggle(isOn: dailyReminderEnabledBinding) {
                        Label("Daily transaction reminder", systemImage: "bell.badge")
                    }
                    .disabled(isUpdatingDailyReminder)
                    .accessibilityIdentifier("daily-transaction-reminder-toggle")

                    DatePicker(
                        "Reminder time",
                        selection: dailyReminderTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .disabled(isUpdatingDailyReminder)
                    .accessibilityIdentifier("daily-transaction-reminder-time")

                    Text("Get a daily notification to add today’s transactions. Notification access is requested when you enable this reminder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle(isOn: budgetThresholdAlertsBinding) {
                        Label("Budget threshold alerts", systemImage: "chart.pie")
                    }
                    .disabled(isUpdatingBudgetAlerts)

                    Text("Get a local alert when spending crosses 80% or 100% of a budget. Amounts and category names stay out of the notification.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let budgetAlertStatus {
                        Text(budgetAlertStatus)
                            .font(.footnote)
                            .foregroundStyle(budgetAlertStatus.contains("Allow notifications")
                                ? PocketLedgerTheme.warning
                                : PocketLedgerTheme.textSecondary)
                    }

                    Toggle(isOn: $isScheduledLiveActivityEnabled) {
                        Label("Scheduled transaction countdown", systemImage: "timer")
                    }
                    .accessibilityIdentifier("scheduled-transaction-live-activity-toggle")

                    Text("Shows the next scheduled transaction, expected amount, and countdown during the eight hours before it is due. Private details are hidden when iOS requests privacy redaction.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Timing and setup") {
                        Text(
                            "Groups up to three upcoming scheduled entries in one private countdown, and counts any additional entries in the same window. "
                                + "It stays hidden until the next enabled entry is due within eight hours; scheduled notifications follow their selected reminder time independently. "
                                + "Due entries are added when Pocket Ledger next opens. Enable Live Activities in Settings > Apps > Pocket Ledger, and allow them on the Lock Screen in Settings > Face ID & Passcode > Allow Access When Locked."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if let dailyReminderStatus {
                        Text(dailyReminderStatus)
                            .font(.footnote)
                            .foregroundStyle(
                                dailyReminderStatus.contains("Allow notifications")
                                    ? PocketLedgerTheme.warning
                                    : PocketLedgerTheme.textSecondary
                            )
                    }
                }

                Section("App lock") {
                    if security.isPasscodeEnabled {
                        Label("Passcode enabled", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(PocketLedgerTheme.positive)

                        Button("Change passcode") {
                            passcodeSheet = .change
                        }

                        Button("Remove passcode", role: .destructive) {
                            isShowingRemoveConfirmation = true
                        }
                    } else {
                        Label("App lock is off", systemImage: "lock.open")
                            .foregroundStyle(.secondary)

                        Button {
                            passcodeSheet = .set
                        } label: {
                            Label("Set app passcode", systemImage: "lock.fill")
                        }
                    }

                    if security.isPasscodeEnabled {
                        Text("Your passcode is protected by the iPhone Keychain. After five incorrect attempts, you’ll need to wait before trying again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Biometric unlock") {
                    Toggle(isOn: biometricsBinding) {
                        Label(
                            "Unlock with \(security.biometricName)",
                            systemImage: security.availableBiometry?.systemImage ?? "touchid"
                        )
                    }
                    .disabled(
                        !security.isPasscodeEnabled
                            || security.availableBiometry == nil
                            || isUpdatingBiometrics
                    )

                    if !security.isPasscodeEnabled {
                        Text("Set an app passcode first. Biometrics unlocks the app passcode screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if security.availableBiometry == nil {
                        Text("Set up Face ID or Touch ID in the device settings before enabling biometric unlock.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You will confirm your identity once when enabling this option.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Privacy") {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    Text("Financial values in widgets and watch complications are marked private so the system can redact them on the Lock Screen and during Always On. Widget and App Intent actions that change your ledger require authentication.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
                    NavigationLink {
                        DataTransferView(store: store)
                    } label: {
                        Label("Import & Backup", systemImage: "arrow.down.doc")
                    }
                }
            }
            .pocketListSurface()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $passcodeSheet) { sheet in
                PasscodeSetupView(security: security, mode: sheet)
            }
            .confirmationDialog(
                "Remove your app passcode?",
                isPresented: $isShowingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove passcode", role: .destructive, action: removePasscode)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The app will remain unlocked until you set a new passcode.")
            }
            .errorMessageAlert(title: "Security setting not changed", message: $errorMessage)
            .onChange(of: isScheduledLiveActivityEnabled) { _, _ in
                Task {
                    await NotificationService.refreshScheduledTransactionNotifications(
                        schedules: store.data.scheduledTransactions
                    )
                }
            }
    }

    private var dailyReminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { isDailyTransactionReminderEnabled },
            set: { updateDailyTransactionReminder(isEnabled: $0) }
        )
    }

    private var dailyReminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: dailyTransactionReminderMinutes / 60,
                    minute: dailyTransactionReminderMinutes % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                dailyTransactionReminderMinutes = (components.hour ?? 20) * 60
                    + (components.minute ?? 0)
                if isDailyTransactionReminderEnabled {
                    updateDailyTransactionReminder(isEnabled: true)
                }
            }
        )
    }

    private var budgetThresholdAlertsBinding: Binding<Bool> {
        Binding(
            get: { areBudgetThresholdAlertsEnabled },
            set: { updateBudgetThresholdAlerts(isEnabled: $0) }
        )
    }

    private func updateDailyTransactionReminder(isEnabled: Bool) {
        guard !isUpdatingDailyReminder else { return }
        isDailyTransactionReminderEnabled = isEnabled
        isUpdatingDailyReminder = true

        Task {
            defer { isUpdatingDailyReminder = false }
            if isEnabled {
                do {
                    try await NotificationService.enableDailyTransactionReminder(
                        minutesAfterMidnight: dailyTransactionReminderMinutes
                    )
                    dailyReminderStatus = "Daily transaction reminder is enabled."
                } catch {
                    isDailyTransactionReminderEnabled = false
                    dailyReminderStatus = error.localizedDescription
                }
            } else {
                NotificationService.disableDailyTransactionReminder()
                dailyReminderStatus = "Daily transaction reminder is off."
            }
        }
    }

    private func updateBudgetThresholdAlerts(isEnabled: Bool) {
        guard !isUpdatingBudgetAlerts else { return }
        isUpdatingBudgetAlerts = true
        if !isEnabled {
            NotificationService.disableBudgetThresholdAlerts()
            areBudgetThresholdAlertsEnabled = false
            budgetAlertStatus = "Budget alerts are off."
            isUpdatingBudgetAlerts = false
            return
        }
        Task {
            defer { isUpdatingBudgetAlerts = false }
            do {
                try await NotificationService.enableBudgetThresholdAlerts()
                areBudgetThresholdAlertsEnabled = true
                budgetAlertStatus = "Budget alerts are enabled."
            } catch {
                areBudgetThresholdAlertsEnabled = false
                budgetAlertStatus = error.localizedDescription
            }
        }
    }

    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { security.biometricsEnabled },
            set: { enabled in
                guard !isUpdatingBiometrics else { return }
                isUpdatingBiometrics = true
                Task {
                    do {
                        try await security.setBiometricsEnabled(enabled)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isUpdatingBiometrics = false
                }
            }
        )
    }

    private func removePasscode() {
        do {
            try security.removePasscode()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct PasscodeSetupView: View {
    @ObservedObject var security: AppSecurityService
    let mode: PasscodeSheet

    @Environment(\.dismiss) private var dismiss
    @State private var currentPasscode = ""
    @State private var newPasscode = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if mode == .change {
                    Section("Current passcode") {
                        passcodeField("Current passcode", text: $currentPasscode)
                    }
                }

                Section("New passcode") {
                    passcodeField("4 to 6 digits", text: $newPasscode)
                    passcodeField("Confirm passcode", text: $confirmation)
                }

                Section {
                    Label(
                        "The passcode is stored securely on this device and cannot be recovered if forgotten.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .pocketListSurface()
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .errorMessageAlert(title: "Passcode not saved", message: $errorMessage)
        }
    }

    private func passcodeField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .keyboardType(.numberPad)
            .onChange(of: text.wrappedValue) { _, value in
                let sanitized = AppPasscodeRules.sanitized(value)
                if sanitized != value {
                    text.wrappedValue = sanitized
                }
            }
    }

    private var canSave: Bool {
        AppPasscodeRules.isValid(newPasscode)
            && newPasscode == confirmation
            && (mode == .set || AppPasscodeRules.isValid(currentPasscode))
    }

    private func save() {
        guard AppPasscodeRules.isValid(newPasscode) else {
            errorMessage = "Use a passcode with 4 to 6 digits."
            return
        }
        guard newPasscode == confirmation else {
            errorMessage = "The passcodes do not match."
            return
        }
        if mode == .change && !security.verifyPasscode(currentPasscode) {
            let seconds = security.passcodeLockoutRemainingSeconds
            errorMessage = seconds > 0
                ? "Too many incorrect attempts. Try again in \(seconds) seconds."
                : "The current passcode is incorrect."
            return
        }

        do {
            try security.setPasscode(newPasscode)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct AppLockView: View {
    @ObservedObject var security: AppSecurityService
    @Binding var isUnlocked: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var passcode = ""
    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var shouldRetryBiometricsOnActivation = false

    var body: some View {
        ZStack {
            PocketLedgerTheme.background
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer()

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(PocketLedgerTheme.accent)

                        VStack(spacing: 8) {
                            Text("Pocket Ledger is locked")
                                .font(.title2.weight(.bold))
                            Text("Enter your app passcode to view your financial data.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        SecureField("App passcode", text: $passcode)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                            .onChange(of: passcode) { _, value in
                                let sanitized = AppPasscodeRules.sanitized(value)
                                if sanitized != value {
                                    passcode = sanitized
                                }
                            }

                        Button("Unlock", action: unlockWithPasscode)
                            .buttonStyle(.glassProminent)
                            .tint(PocketLedgerTheme.accent)
                            .disabled(!AppPasscodeRules.isValid(passcode))

                        if security.biometricsEnabled {
                            Button {
                                Task { await unlockWithBiometrics() }
                            } label: {
                                Label(
                                    "Unlock with \(security.biometricName)",
                                    systemImage: security.availableBiometry?.systemImage ?? "touchid"
                                )
                            }
                            .disabled(isAuthenticating)
                        }

                        if isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(PocketLedgerTheme.accent)
                                .multilineTextAlignment(.center)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 64))
                    .padding(32)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(PocketLedgerTheme.textPrimary)
        .tint(PocketLedgerTheme.accent)
        .preferredColorScheme(PocketLedgerTheme.appearanceMode.preferredColorScheme)
        .onAppear {
            requestBiometricUnlockIfPossible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                shouldRetryBiometricsOnActivation = true
            } else if phase == .active, shouldRetryBiometricsOnActivation {
                shouldRetryBiometricsOnActivation = false
                requestBiometricUnlockIfPossible()
            }
        }
    }

    private func requestBiometricUnlockIfPossible() {
        guard scenePhase == .active, !isUnlocked, !isAuthenticating else { return }
        Task {
            await unlockWithBiometrics()
        }
    }

    private func unlockWithPasscode() {
        guard security.verifyPasscode(passcode) else {
            passcode = ""
            let seconds = security.passcodeLockoutRemainingSeconds
            errorMessage = seconds > 0
                ? "Too many incorrect attempts. Try again in \(seconds) seconds."
                : "That passcode is incorrect."
            return
        }

        errorMessage = nil
        isUnlocked = true
    }

    private func unlockWithBiometrics() async {
        guard security.biometricsEnabled, !isAuthenticating else { return }

        isAuthenticating = true
        let authenticated = await security.authenticateWithBiometrics()
        isAuthenticating = false

        if authenticated, scenePhase != .background {
            errorMessage = nil
            isUnlocked = true
        } else if !Task.isCancelled, scenePhase != .background {
            errorMessage = "Biometric unlock was not completed. Enter your app passcode to continue."
        }
    }
}

private struct PrivacyPolicyView: View {
    var body: some View {
        Form {
            Section("Information stored") {
                Text("Pocket Ledger stores your accounts, balances, transactions, categories, budgets, schedules, preferences, and any receipt files you choose to save in local app storage. When the shared app group is available, Pocket Ledger widgets use the same ledger storage.")
                Text("You add ledger details by entering them in the app or importing files you select. Receipt photos or PDFs are added when you choose to scan or attach them.")
                Text("If you use the paired Apple Watch app, selected ledger data is synchronized to that Watch so its screens can work.")
            }

            Section("How information is used") {
                Text("The app uses this information to provide ledger, budget, reporting, widget, Watch, receipt scanning, and import or backup features.")
                Text("Receipt scanning and optional writing assistance use on-device processing. Pocket Ledger does not send ledger data to a developer-operated server, third-party analytics service, advertising network, or third-party AI service.")
            }

            Section("Permissions and sharing") {
                Text("The camera, selected photos, or files are accessed only when you choose to scan or attach a receipt, or import a ledger file. Face ID or Touch ID is handled by Apple’s LocalAuthentication system; Pocket Ledger receives the authentication result, not your biometric data. Optional reminders are scheduled as local notifications.")
                Text("When you export or share ledger information or a backup, the app hands the selected content to the destination you choose in the system share or file picker. That destination’s own privacy practices apply to the exported copy.")
            }

            Section("Retention and deletion") {
                Text("The active ledger remains in local app storage until you delete records or erase it in Settings → Data → Import & Backup. Before a reset or replacement, Pocket Ledger keeps one local last-good recovery snapshot that may include receipt files. It remains until replaced by a later snapshot or deleted from the recovery card in Import & Backup. Pocket Ledger keeps no server-side ledger copy.")
                Text("Exported backups and copies shared with another app are outside Pocket Ledger’s control; delete them from the destination where you saved or shared them. You can revoke camera, photo, and notification permissions in iOS Settings.")
            }

            Section("Contact") {
                Text("For privacy questions, email:")
                Link("joelteif11@gmail.com", destination: URL(string: "mailto:joelteif11@gmail.com")!)
            }
        }
        .pocketListSurface()
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
