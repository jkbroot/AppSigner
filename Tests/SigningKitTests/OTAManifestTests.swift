import XCTest
@testable import SigningKit

final class OTAManifestTests: XCTestCase {
    private func parse(_ xml: String) throws -> [String: Any] {
        try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), format: nil) as? [String: Any])
    }

    func testBuildsItmsServicesManifest() throws {
        let xml = OTAManifest.plist(ipaURL: "https://10.0.0.5:8443/app.ipa",
                                    bundleID: "com.example.app", version: "1.2.3", title: "My App")
        let root = try parse(xml)
        let item = try XCTUnwrap((root["items"] as? [[String: Any]])?.first)

        let assets = try XCTUnwrap(item["assets"] as? [[String: Any]])
        let package = try XCTUnwrap(assets.first { $0["kind"] as? String == "software-package" })
        XCTAssertEqual(package["url"] as? String, "https://10.0.0.5:8443/app.ipa")

        let metadata = try XCTUnwrap(item["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["bundle-identifier"] as? String, "com.example.app")
        XCTAssertEqual(metadata["bundle-version"] as? String, "1.2.3")
        XCTAssertEqual(metadata["title"] as? String, "My App")
        XCTAssertEqual(metadata["kind"] as? String, "software")
    }

    func testEscapesSpecialCharactersInTitle() throws {
        let xml = OTAManifest.plist(ipaURL: "https://h/app.ipa",
                                    bundleID: "com.a.b", version: "1", title: "Tom & Jerry <fun>")
        let metadata = try XCTUnwrap((try parse(xml)["items"] as? [[String: Any]])?.first?["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["title"] as? String, "Tom & Jerry <fun>")
    }
}
