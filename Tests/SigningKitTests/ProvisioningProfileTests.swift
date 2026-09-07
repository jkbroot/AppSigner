import XCTest
@testable import SigningKit

final class ProvisioningProfileTests: XCTestCase {
    private var sampleURL: URL { Fixtures.sampleProfileURL }

    func testParsesTeamIdentifier() throws {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: sampleURL))
        XCTAssertEqual(profile.teamIdentifier, "ABCDE12345")
    }

    func testParsesWildcardApplicationIdentifier() throws {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: sampleURL))
        XCTAssertEqual(profile.applicationIdentifier, "ABCDE12345.*")
    }

    func testExtractsDeveloperCertificateSHA1Fingerprints() throws {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: sampleURL))
        // SHA-1 of the fixture's certificate bytes ("TESTCERT").
        XCTAssertEqual(profile.developerCertificateSHA1s, ["11D69DADBA60712BCC4E61DD6B00FE14E9AC912B"])
    }

    func testDerivesAdHocProfileType() throws {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: sampleURL))
        XCTAssertEqual(profile.type, .adHoc)
        XCTAssertFalse(profile.isExpired, "fixture expires in 2099")
        XCTAssertEqual(profile.provisionedDeviceCount, 2)
    }

    func testRejectsNonProfileData() {
        XCTAssertThrowsError(try ProvisioningProfile.parse(data: Data("not a profile".utf8)))
    }
}
