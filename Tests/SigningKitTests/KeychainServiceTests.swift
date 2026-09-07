import XCTest
@testable import SigningKit

final class KeychainServiceTests: XCTestCase {

    // MARK: Pure matching logic (synthetic data)

    func testMatchesIdentitiesByCertificateFingerprint() {
        let ids = [
            SigningIdentity(sha1: "AAAA", commonName: "Apple Development: X"),
            SigningIdentity(sha1: "8AA12777ACDCFD01455945954CB0F9FA657A26A3",
                            commonName: "iPhone Distribution: Yaqoob Alkhanbashi (224K3NKKQX)"),
            SigningIdentity(sha1: "BBBB", commonName: "Apple Development: Y"),
        ]
        let matches = KeychainService.identities(
            ids, matchingCertificateSHA1s: ["8AA12777ACDCFD01455945954CB0F9FA657A26A3"]
        )
        XCTAssertEqual(matches.map(\.sha1), ["8AA12777ACDCFD01455945954CB0F9FA657A26A3"])
    }

    func testMatchIsCaseInsensitiveOnFingerprint() {
        let ids = [SigningIdentity(sha1: "8aa12777acdcfd01455945954cb0f9fa657a26a3", commonName: "X")]
        let matches = KeychainService.identities(
            ids, matchingCertificateSHA1s: ["8AA12777ACDCFD01455945954CB0F9FA657A26A3"]
        )
        XCTAssertEqual(matches.count, 1)
    }

    func testNoMatchReturnsEmpty() {
        let ids = [SigningIdentity(sha1: "AAAA", commonName: "X")]
        XCTAssertTrue(KeychainService.identities(ids, matchingCertificateSHA1s: ["ZZZZ"]).isEmpty)
    }

    // MARK: Real keychain enumeration (depends on the imported AppSigner cert)

    func testListsCodeSigningIdentitiesWithoutThrowing() throws {
        // Environment-independent: the machine may have zero or more identities.
        let ids = try KeychainService().listCodeSigningIdentities()
        for id in ids {
            XCTAssertFalse(id.sha1.isEmpty)
            XCTAssertEqual(id.sha1, id.sha1.uppercased(), "fingerprints are uppercase hex")
        }
    }
}
