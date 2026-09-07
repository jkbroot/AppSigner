import XCTest
@testable import SigningKit

final class IPAInfoTests: XCTestCase {
    private var fm: FileManager { .default }

    func testReadsAppInfoWithoutFullUnpack() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipainfo-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Payload/Demo.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.demo.app",
            "CFBundleDisplayName": "Demo",
            "CFBundleShortVersionString": "3.1",
            "CFBundleVersion": "99",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("bin".utf8).write(to: app.appendingPathComponent("Demo"))

        let ipa = root.appendingPathComponent("demo.ipa")
        try ProcessRunner().runThrowing("/usr/bin/zip", ["-r", "-q", "demo.ipa", "Payload"], cwd: root)

        let appInfo = try IPAPackage.readAppInfo(ipa: ipa)
        XCTAssertEqual(appInfo.bundleID, "com.demo.app")
        XCTAssertEqual(appInfo.displayName, "Demo")
        XCTAssertEqual(appInfo.shortVersion, "3.1")
        XCTAssertEqual(appInfo.bundleVersion, "99")
        XCTAssertEqual(appInfo.appBundleName, "Demo.app")
    }
}
