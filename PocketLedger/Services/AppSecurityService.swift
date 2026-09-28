import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum AppPasscodeRules {
    static let minimumLength = 4
    static let maximumLength = 6

    static func sanitized(_ value: String) -> String {
        String(
            decoding: value.unicodeScalars
                .filter { scalar in
                    scalar.value >= 48 && scalar.value <= 57
                }
                .prefix(maximumLength)
                .map { UInt8($0.value) },
            as: UTF8.self
        )
    }

    static func isValid(_ value: String) -> Bool {
        let sanitizedValue = sanitized(value)
        return sanitizedValue == value
            && (minimumLength...maximumLength).contains(value.count)
    }
}

enum AppSecurityError: LocalizedError {
    case invalidPasscode
    case keychainUnavailable
    case biometricUnavailable
    case biometricNotVerified
    case passcodeRequired

    var errorDescription: String? {
        switch self {
        case .invalidPasscode:
            return "Use a passcode with 4 to 6 digits."
        case .keychainUnavailable:
            return "The passcode could not be stored securely on this device."
        case .biometricUnavailable:
            return "Face ID or Touch ID is not available on this device."
        case .biometricNotVerified:
            return "Biometric verification was not completed."
        case .passcodeRequired:
            return "Set an app passcode before enabling biometrics."
        }
    }
}

enum AppBiometry: Equatable {
    case faceID
    case touchID
    case opticID

    var displayName: String {
        switch self {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        }
    }

    var systemImage: String {
        switch self {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        }
    }
}

@MainActor
final class AppSecurityService: ObservableObject {
    private static let keychainService = "com.josephlteif.financedemo.security"
    private static let keychainAccount = "app-passcode-verifier"
    private static let passcodeConfiguredKey = "appPasscodeConfigured"
    private static let biometricsEnabledKey = "appBiometricsEnabled"
    private static let passcodeLockoutThreshold = 5
    private static let passcodeLockoutStep: TimeInterval = 15
    private static let maximumPasscodeLockout: TimeInterval = 5 * 60

    private struct PasscodeRecord: Codable {
        let salt: Data
        let digest: Data
        var failedAttempts: Int?
        var blockedUntil: Date?
    }

    @Published private(set) var isPasscodeEnabled: Bool
    @Published private(set) var biometricsEnabled: Bool
    private(set) var isBiometricPromptActive = false

    private var passcodeRecord: PasscodeRecord?

    init() {
        let record = Self.readPasscodeRecord()
        let configured = UserDefaults.standard.bool(forKey: Self.passcodeConfiguredKey)
        let passcodeEnabled = record != nil || configured
        passcodeRecord = record
        isPasscodeEnabled = passcodeEnabled
        biometricsEnabled = passcodeEnabled && UserDefaults.standard.bool(forKey: Self.biometricsEnabledKey)
    }

    var availableBiometry: AppBiometry? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }

        switch context.biometryType {
        case .none:
            return nil
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        @unknown default:
            return nil
        }
    }

    var biometricName: String {
        availableBiometry?.displayName ?? "Biometrics"
    }

    var passcodeLockoutRemainingSeconds: Int {
        guard let blockedUntil = passcodeRecord?.blockedUntil else { return 0 }
        return max(0, Int(ceil(blockedUntil.timeIntervalSinceNow)))
    }

    func setPasscode(_ passcode: String) throws {
        guard AppPasscodeRules.isValid(passcode) else {
            throw AppSecurityError.invalidPasscode
        }

        let salt = try Self.makeSalt()
        let record = PasscodeRecord(
            salt: salt,
            digest: Self.digest(for: passcode, salt: salt),
            failedAttempts: 0,
            blockedUntil: nil
        )
        try Self.writePasscodeRecord(record)

        UserDefaults.standard.set(true, forKey: Self.passcodeConfiguredKey)
        passcodeRecord = record
        isPasscodeEnabled = true
    }

    func verifyPasscode(_ passcode: String) -> Bool {
        guard var record = passcodeRecord,
              AppPasscodeRules.isValid(passcode) else {
            return false
        }

        let now = Date()
        if let blockedUntil = record.blockedUntil, blockedUntil > now {
            return false
        }

        let matches = Self.constantTimeEqual(
            Self.digest(for: passcode, salt: record.salt),
            record.digest
        )
        if matches {
            if (record.failedAttempts ?? 0) > 0 || record.blockedUntil != nil {
                record.failedAttempts = 0
                record.blockedUntil = nil
                passcodeRecord = record
                try? Self.writePasscodeRecord(record)
            }
            return true
        }

        let failedAttempts = (record.failedAttempts ?? 0) + 1
        record.failedAttempts = failedAttempts
        let lockoutDuration = Self.passcodeLockoutDuration(after: failedAttempts)
        record.blockedUntil = lockoutDuration > 0
            ? now.addingTimeInterval(lockoutDuration)
            : nil
        passcodeRecord = record
        try? Self.writePasscodeRecord(record)
        return false
    }

    func removePasscode() throws {
        try Self.deletePasscodeRecord()

        UserDefaults.standard.removeObject(forKey: Self.passcodeConfiguredKey)
        passcodeRecord = nil
        isPasscodeEnabled = false
        biometricsEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.biometricsEnabledKey)
    }

    func refresh() {
        guard let record = Self.readPasscodeRecord() else { return }

        passcodeRecord = record
        isPasscodeEnabled = true
        biometricsEnabled = UserDefaults.standard.bool(forKey: Self.biometricsEnabledKey)
    }

    func setBiometricsEnabled(_ enabled: Bool) async throws {
        guard isPasscodeEnabled else {
            throw AppSecurityError.passcodeRequired
        }

        if enabled {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw AppSecurityError.biometricUnavailable
            }

            isBiometricPromptActive = true
            defer { isBiometricPromptActive = false }
            do {
                let verified = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Confirm biometric unlock for Pocket Ledger."
                )
                guard verified else {
                    throw AppSecurityError.biometricNotVerified
                }
            } catch let error as AppSecurityError {
                throw error
            } catch {
                throw AppSecurityError.biometricNotVerified
            }
        }

        UserDefaults.standard.set(enabled, forKey: Self.biometricsEnabledKey)
        biometricsEnabled = enabled
    }

    func authenticateWithBiometrics() async -> Bool {
        guard isPasscodeEnabled,
              biometricsEnabled else {
            return false
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        isBiometricPromptActive = true
        defer { isBiometricPromptActive = false }
        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock your Pocket Ledger data."
            )
            if authenticated {
                resetPasscodeRetryState()
            }
            return authenticated
        } catch {
            return false
        }
    }

    func authenticateToRevealBalances() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        isBiometricPromptActive = true
        defer { isBiometricPromptActive = false }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Reveal your Pocket Ledger balances."
            )
        } catch {
            return false
        }
    }

    private func resetPasscodeRetryState() {
        guard var record = passcodeRecord,
              (record.failedAttempts ?? 0) > 0 || record.blockedUntil != nil else {
            return
        }

        record.failedAttempts = 0
        record.blockedUntil = nil
        passcodeRecord = record
        try? Self.writePasscodeRecord(record)
    }

    private static func passcodeLockoutDuration(after failedAttempts: Int) -> TimeInterval {
        guard failedAttempts >= passcodeLockoutThreshold else { return 0 }
        let exponent = min(failedAttempts - passcodeLockoutThreshold, 5)
        return min(passcodeLockoutStep * pow(2, Double(exponent)), maximumPasscodeLockout)
    }

    private static func makeSalt() throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw AppSecurityError.keychainUnavailable
        }
        return salt
    }

    private static func digest(for passcode: String, salt: Data) -> Data {
        var input = Data()
        input.append(salt)
        input.append(contentsOf: passcode.utf8)
        return Data(SHA256.hash(data: input))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }

        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func readPasscodeRecord() -> PasscodeRecord? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(PasscodeRecord.self, from: data)
    }

    private static func writePasscodeRecord(_ record: PasscodeRecord) throws {
        guard let data = try? JSONEncoder().encode(record) else {
            throw AppSecurityError.keychainUnavailable
        }

        let query = keychainQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw AppSecurityError.keychainUnavailable
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw AppSecurityError.keychainUnavailable
        }
    }

    private static func deletePasscodeRecord() throws {
        let status = SecItemDelete(keychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppSecurityError.keychainUnavailable
        }
    }
}
