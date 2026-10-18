import Darwin
import Foundation
import Security
import SwiftASN1
import X509

enum LocalWebCertificate {
    struct ServerIdentity {
        let identity: SecIdentity
        let caCertificateDER: Data
    }

    private struct Authority {
        let signingKey: Certificate.PrivateKey
        let certificate: Certificate
        let certificateDER: Data
    }

    private enum CertificateError: LocalizedError {
        case invalidIPv4Address
        case keyGeneration
        case keychain(OSStatus)
        case invalidStoredCertificate
        case identityCreation

        var errorDescription: String? {
            switch self {
            case .invalidIPv4Address:
                return "Enter a valid IPv4 address."
            case .keyGeneration:
                return "Could not create the local web certificate key."
            case .keychain(let status):
                return "Could not access the local web certificate in Keychain (\(status))."
            case .invalidStoredCertificate:
                return "The stored local web certificate is invalid."
            case .identityCreation:
                return "Could not create the local web server identity."
            }
        }
    }

    private static let lock = NSLock()
    private static let caKeyTag = Data("com.pocketledger.local-web.ca-key.v1".utf8)
    private static let caCertificateService = "com.pocketledger.local-web.ca-certificate"
    private static let caCertificateAccount = "root"
    private static let caCommonName = "Pocket Ledger Local Web CA"

    static func issueServerIdentity(forIPv4Address address: String) throws -> ServerIdentity {
        let addressBytes = try ipv4Bytes(from: address)

        lock.lock()
        defer { lock.unlock() }

        let authority = try loadOrCreateAuthority()
        let privateKey = try Self.createPrivateKey()
        let signingKey = try Certificate.PrivateKey(privateKey)
        let now = Date()
        let name = try distinguishedName("Pocket Ledger Local Web Server")
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            try SubjectAlternativeNames([
                .ipAddress(ASN1OctetString(contentBytes: addressBytes[...]))
            ])
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(7 * 24 * 60 * 60),
            issuer: authority.certificate.subject,
            subject: name,
            extensions: extensions,
            issuerPrivateKey: authority.signingKey
        )
        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        guard let identity = SecIdentityCreate(nil, secCertificate, privateKey) else {
            throw CertificateError.identityCreation
        }

        return ServerIdentity(identity: identity, caCertificateDER: authority.certificateDER)
    }

    static func authorityCertificateDER() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try loadOrCreateAuthority().certificateDER
    }

    private static func loadOrCreateAuthority() throws -> Authority {
        let (privateKey, isNewKey) = try loadOrCreateCAKey()
        let signingKey = try Certificate.PrivateKey(privateKey)

        if let storedDER = try loadCACertificateDER(), !isNewKey {
            let certificate = try Certificate(derEncoded: [UInt8](storedDER))
            guard certificate.publicKey == signingKey.publicKey else {
                throw CertificateError.invalidStoredCertificate
            }
            return Authority(signingKey: signingKey, certificate: certificate, certificateDER: storedDER)
        }

        let now = Date()
        let name = try distinguishedName(caCommonName)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(keyCertSign: true))
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 60 * 60),
            issuer: name,
            subject: name,
            extensions: extensions,
            issuerPrivateKey: signingKey
        )
        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        let der = SecCertificateCopyData(secCertificate) as Data
        try storeCACertificateDER(der)
        return Authority(signingKey: signingKey, certificate: certificate, certificateDER: der)
    }

    private static func loadOrCreateCAKey() throws -> (SecKey, isNew: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: caKeyTag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let keyReference = result else { throw CertificateError.keychain(errSecDecode) }
            return (keyReference as! SecKey, false)
        }
        guard status == errSecItemNotFound else { throw CertificateError.keychain(status) }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: caKeyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrCanSign as String: true
            ]
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            if let creationError { throw creationError.takeRetainedValue() as Error }
            throw CertificateError.keyGeneration
        }
        return (key, true)
    }

    private static func createPrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            if let creationError { throw creationError.takeRetainedValue() as Error }
            throw CertificateError.keyGeneration
        }
        return key
    }

    private static func loadCACertificateDER() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: caCertificateService,
            kSecAttrAccount as String: caCertificateAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else { throw CertificateError.keychain(errSecDecode) }
            return data
        }
        guard status == errSecItemNotFound else { throw CertificateError.keychain(status) }
        return nil
    }

    private static func storeCACertificateDER(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: caCertificateService,
            kSecAttrAccount as String: caCertificateAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CertificateError.keychain(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CertificateError.keychain(addStatus) }
    }

    private static func ipv4Bytes(from address: String) throws -> [UInt8] {
        var parsedAddress = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &parsedAddress) }) == 1 else {
            throw CertificateError.invalidIPv4Address
        }
        return withUnsafeBytes(of: parsedAddress.s_addr) { Array($0) }
    }

    private static func distinguishedName(_ commonName: String) throws -> DistinguishedName {
        try DistinguishedName {
            CommonName(commonName)
        }
    }
}
