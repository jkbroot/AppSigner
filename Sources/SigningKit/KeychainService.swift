import Foundation
import Security
import CryptoKit

/// A code-signing identity (certificate + private key) available in the Keychain.
public struct SigningIdentity: Equatable {
    /// Uppercase hex SHA-1 of the certificate's DER data (matches profile fingerprints).
    public let sha1: String
    /// Certificate common name, e.g. "iPhone Distribution: Name (TEAMID)".
    public let commonName: String

    public init(sha1: String, commonName: String) {
        self.sha1 = sha1
        self.commonName = commonName
    }
}

/// Reads code-signing identities directly from the Keychain (no `security` shell-out).
public struct KeychainService {
    public init() {}

    public enum KeychainError: Error, LocalizedError {
        case queryFailed(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .queryFailed(let s): return "Keychain query failed (OSStatus \(s))."
            }
        }
    }

    /// Filters identities whose certificate fingerprint is authorized by the given profile certs.
    /// Comparison is case-insensitive on the hex fingerprint.
    public static func identities(_ identities: [SigningIdentity],
                                  matchingCertificateSHA1s fingerprints: [String]) -> [SigningIdentity] {
        let wanted = Set(fingerprints.map { $0.uppercased() })
        return identities.filter { wanted.contains($0.sha1.uppercased()) }
    }

    /// Enumerates identities valid for code signing.
    public func listCodeSigningIdentities() throws -> [SigningIdentity] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        if let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) {
            query[kSecMatchPolicy as String] = policy
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.queryFailed(status) }

        let secIdentities = (result as? [SecIdentity]) ?? []
        return secIdentities.compactMap { Self.identity(from: $0) }
    }

    private static func identity(from secIdentity: SecIdentity) -> SigningIdentity? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &cert) == errSecSuccess,
              let certificate = cert else { return nil }

        let der = SecCertificateCopyData(certificate) as Data
        let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()

        var cn: CFString?
        SecCertificateCopyCommonName(certificate, &cn)
        let commonName = (cn as String?) ?? "(unknown)"

        return SigningIdentity(sha1: sha1, commonName: commonName)
    }
}
