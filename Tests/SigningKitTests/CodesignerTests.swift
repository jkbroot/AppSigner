import XCTest
@testable import SigningKit

final class CodesignerTests: XCTestCase {
    private var sampleURL: URL { Fixtures.sampleProfileURL }

    func testProfileExposesEntitlements() throws {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: sampleURL))
        XCTAssertEqual(profile.entitlements["application-identifier"] as? String, "ABCDE12345.*")
    }

    func testWritesEntitlementsPlistFromProfile() throws {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: sampleURL))
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ent-\(UUID().uuidString).plist")
        try Codesigner().writeEntitlements(profile, to: out)

        let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: out), format: nil) as? [String: Any]
        XCTAssertEqual(dict?["application-identifier"] as? String, "ABCDE12345.*")
        XCTAssertEqual(dict?["com.apple.developer.team-identifier"] as? String, "ABCDE12345")
    }
}
