import Foundation
import Security

/// A self-signed TLS identity for the local OTA server, plus its certificate so the
/// device can be told to trust it.
public struct OTACertificate {
    public let identity: SecIdentity
    public let certificatePEM: Data
    public let commonName: String
}

public enum OTACertificateError: Error {
    case opensslFailed(String)
    case importFailed(OSStatus)
    case noIdentity
}

/// Generates a fresh self-signed certificate with `/usr/bin/openssl` (a macOS system
/// tool) and imports it as a `SecIdentity` usable for TLS. The certificate carries the
/// server's IP as a Subject Alternative Name, which iOS requires.
public enum OTACertificateFactory {
    public static func generate(ipAddress: String,
                                commonName: String = "AppSigner OTA",
                                runner: ProcessRunner = .init()) throws -> OTACertificate {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ota-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = dir.appendingPathComponent("key.pem")
        let cert = dir.appendingPathComponent("cert.pem")
        let p12 = dir.appendingPathComponent("identity.p12")
        let password = UUID().uuidString

        // Self-signed cert + key with the IP in the SAN.
        let req = try runner.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "30", "-nodes",
            "-keyout", key.path, "-out", cert.path,
            "-subj", "/CN=\(commonName)",
            "-addext", "subjectAltName=IP:\(ipAddress)",
        ])
        guard FileManager.default.fileExists(atPath: cert.path) else {
            throw OTACertificateError.opensslFailed(req.stderr)
        }

        // Bundle key + cert into a PKCS#12 so it can be imported as an identity.
        let export = try runner.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
            "-out", p12.path, "-passout", "pass:\(password)",
        ])
        guard FileManager.default.fileExists(atPath: p12.path) else {
            throw OTACertificateError.opensslFailed(export.stderr)
        }

        let identity = try importIdentity(p12Data: try Data(contentsOf: p12), password: password)
        return OTACertificate(identity: identity,
                              certificatePEM: try Data(contentsOf: cert),
                              commonName: commonName)
    }

    private static func importIdentity(p12Data: Data, password: String) throws -> SecIdentity {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options, &items)
        guard status == errSecSuccess else { throw OTACertificateError.importFailed(status) }
        guard let first = (items as? [[String: Any]])?.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw OTACertificateError.noIdentity
        }
        return identityRef as! SecIdentity
    }
}
