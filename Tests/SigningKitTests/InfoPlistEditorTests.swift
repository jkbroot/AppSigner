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

// MARK: - Advanced editing

extension InfoPlistEditorTests {
    /// A richer Info.plist covering the keys the advanced editor touches.
    private func makeRichPlist() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rich-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Info.plist")
        let dict: [String: Any] = [
            "CFBundleExecutable": "Demo",
            "CFBundleIdentifier": "com.old.app",
            "MinimumOSVersion": "15.0",
            "UIDeviceFamily": [1],
            "UIRequiredDeviceCapabilities": ["arm64", "metal"],
            "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
            "CFBundleURLTypes": [
                ["CFBundleURLName": "main", "CFBundleURLSchemes": ["demo", "demo-alt"]],
                ["CFBundleURLName": "other", "CFBundleURLSchemes": ["second"]],
            ],
            "LegacyKey": "remove me",
        ]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return url
    }

    private func reload(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    func testSetsMinimumOSVersionAndDeviceFamilies() throws {
        let url = try makeRichPlist()
        var edits = InfoPlistEdits()
        edits.minimumOSVersion = "12.0"
        edits.deviceFamilies = [1, 2]
        try InfoPlistEditor(url: url).apply(edits)

        let dict = try reload(url)
        XCTAssertEqual(dict["MinimumOSVersion"] as? String, "12.0")
        XCTAssertEqual(dict["UIDeviceFamily"] as? [Int], [1, 2])
    }

    func testFileSharingSetsBothKeys() throws {
        let url = try makeRichPlist()
        var edits = InfoPlistEdits(); edits.fileSharingEnabled = true
        try InfoPlistEditor(url: url).apply(edits)

        let dict = try reload(url)
        XCTAssertEqual(dict["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(dict["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)
    }

    func testArbitraryLoadsMergesIntoExistingATSDictionary() throws {
        let url = try makeRichPlist()
        var edits = InfoPlistEdits(); edits.allowArbitraryLoads = true
        try InfoPlistEditor(url: url).apply(edits)

        let ats = try XCTUnwrap(reload(url)["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true, "existing ATS keys are preserved")
    }

    func testRemovesRequiredDeviceCapabilities() throws {
        let url = try makeRichPlist()
        var edits = InfoPlistEdits(); edits.removeRequiredCapabilities = true
        try InfoPlistEditor(url: url).apply(edits)
        XCTAssertNil(try reload(url)["UIRequiredDeviceCapabilities"])
    }

    func testPrefixesEveryURLScheme() throws {
        let url = try makeRichPlist()
        var edits = InfoPlistEdits(); edits.urlSchemePrefix = "as1"
        try InfoPlistEditor(url: url).apply(edits)

        let types = try XCTUnwrap(reload(url)["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(types[0]["CFBundleURLSchemes"] as? [String], ["as1demo", "as1demo-alt"])
        XCTAssertEqual(types[1]["CFBundleURLSchemes"] as? [String], ["as1second"])
    }

    func testRawKeyRemovalAndTypedCustomValues() throws {
        let url = try makeRichPlist()
        var edits = InfoPlistEdits()
        edits.removedKeys = ["LegacyKey"]
        edits.customValues = [
            "MyString": .string("hello"),
            "MyBool": .bool(true),
            "MyInt": .integer(42),
            "MyArray": .stringArray(["a", "b"]),
        ]
        try InfoPlistEditor(url: url).apply(edits)

        let dict = try reload(url)
        XCTAssertNil(dict["LegacyKey"])
        XCTAssertEqual(dict["MyString"] as? String, "hello")
        XCTAssertEqual(dict["MyBool"] as? Bool, true)
        XCTAssertEqual(dict["MyInt"] as? Int, 42)
        XCTAssertEqual(dict["MyArray"] as? [String], ["a", "b"])
    }

    func testRefusesToTouchTheExecutableKey() throws {
        let url = try makeRichPlist()
        var remove = InfoPlistEdits(); remove.removedKeys = ["CFBundleExecutable"]
        XCTAssertThrowsError(try InfoPlistEditor(url: url).apply(remove)) { error in
            XCTAssertEqual(error as? InfoPlistEditor.EditorError, .protectedKey("CFBundleExecutable"))
        }
        var set = InfoPlistEdits(); set.customValues = ["CFBundleExecutable": .string("Hacked")]
        XCTAssertThrowsError(try InfoPlistEditor(url: url).apply(set))
        XCTAssertEqual(try reload(url)["CFBundleExecutable"] as? String, "Demo", "left untouched")
    }
}
