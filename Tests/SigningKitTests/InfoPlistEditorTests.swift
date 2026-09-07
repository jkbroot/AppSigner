import XCTest
@testable import SigningKit

final class InfoPlistEditorTests: XCTestCase {
    private func makeTempPlist() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iptest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Info.plist")
        let dict: [String: Any] = [
            "CFBundleIdentifier": "com.old.app",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleDisplayName": "OldName",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    func testReadsExistingValue() throws {
        let url = try makeTempPlist()
        let editor = InfoPlistEditor(url: url)
        XCTAssertEqual(try editor.string(forKey: "CFBundleIdentifier"), "com.old.app")
    }

    func testAppliesAllEdits() throws {
        let url = try makeTempPlist()
        let editor = InfoPlistEditor(url: url)
        try editor.apply(InfoPlistEdits(
            bundleIdentifier: "com.new.app",
            shortVersion: "2.5",
            bundleVersion: "42",
            displayName: "NewName"
        ))
        let reloaded = InfoPlistEditor(url: url)
        XCTAssertEqual(try reloaded.string(forKey: "CFBundleIdentifier"), "com.new.app")
        XCTAssertEqual(try reloaded.string(forKey: "CFBundleShortVersionString"), "2.5")
        XCTAssertEqual(try reloaded.string(forKey: "CFBundleVersion"), "42")
        XCTAssertEqual(try reloaded.string(forKey: "CFBundleDisplayName"), "NewName")
    }

    func testNilEditsLeaveValuesUnchanged() throws {
        let url = try makeTempPlist()
        try InfoPlistEditor(url: url).apply(InfoPlistEdits(bundleIdentifier: "com.only.id"))
        let reloaded = InfoPlistEditor(url: url)
        XCTAssertEqual(try reloaded.string(forKey: "CFBundleIdentifier"), "com.only.id")
        XCTAssertEqual(try reloaded.string(forKey: "CFBundleShortVersionString"), "1.0")
    }
}
