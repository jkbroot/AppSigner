import XCTest
import Security
@testable import SigningKit

final class OTACertificateTests: XCTestCase {
    func testGeneratesASelfSignedIdentityForAnIP() throws {
        let cert = try OTACertificateFactory.generate(ipAddress: "127.0.0.1")

        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(cert.identity, &certificate), errSecSuccess)
        let sec = try XCTUnwrap(certificate)

        var cn: CFString?
        SecCertificateCopyCommonName(sec, &cn)
        XCTAssertEqual(cn as String?, "AppSigner OTA")

        XCTAssertFalse(cert.certificatePEM.isEmpty, "the PEM must be available for the device to trust")
        XCTAssertTrue(String(decoding: cert.certificatePEM, as: UTF8.self).contains("BEGIN CERTIFICATE"))
    }
}
