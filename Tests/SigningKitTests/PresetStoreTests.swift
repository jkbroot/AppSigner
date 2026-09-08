import XCTest
@testable import SigningKit

final class PresetStoreTests: XCTestCase {
    private func store() throws -> PresetStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PresetStore(directory: dir)
    }

    private func preset(_ name: String) -> SigningPreset {
        var p = SigningPreset(name: name)
        p.profilePath = "/tmp/a.mobileprovision"
        p.identitySHA1 = "ABC123"
        p.dylibPaths = ["/tmp/x.dylib"]
        p.injectWeak = true
        p.minimumOSVersion = "12.0"
        p.deviceFamilies = [1, 2]
        p.customPlistValues = ["K": .stringArray(["a", "b"])]
        return p
    }

    func testLoadingWithoutAFileReturnsNothing() throws {
        XCTAssertTrue(try store().load().isEmpty)
    }

    func testSavesAndReloadsPresetsIntact() throws {
        let s = try store()
        let original = preset("Ad Hoc")
        try s.save([original])

        let loaded = try XCTUnwrap(PresetStore(directory: s.directory).load().first)
        XCTAssertEqual(loaded, original, "a preset round-trips unchanged")
    }

    func testEveryTypedValueSurvivesTheRoundTrip() throws {
        let s = try store()
        var p = SigningPreset(name: "Types")
        p.customPlistValues = ["s": .string("x"), "b": .bool(true),
                               "i": .integer(7), "l": .stringArray(["a"])]
        try s.save([p])
        let loaded = try XCTUnwrap(s.load().first)
        XCTAssertEqual(loaded.customPlistValues["s"], .string("x"))
        XCTAssertEqual(loaded.customPlistValues["b"], .bool(true))
        XCTAssertEqual(loaded.customPlistValues["i"], .integer(7))
        XCTAssertEqual(loaded.customPlistValues["l"], .stringArray(["a"]))
    }

    func testAddingAPresetWithAnExistingNameReplacesIt() throws {
        let s = try store()
        _ = try s.add(preset("Ad Hoc"))
        var updated = preset("Ad Hoc"); updated.minimumOSVersion = "9.0"
        let all = try s.add(updated)

        XCTAssertEqual(all.count, 1, "same name replaces rather than duplicates")
        XCTAssertEqual(all.first?.minimumOSVersion, "9.0")
    }

    func testAddingDistinctNamesKeepsBoth() throws {
        let s = try store()
        _ = try s.add(preset("One"))
        let all = try s.add(preset("Two"))
        XCTAssertEqual(all.map(\.name).sorted(), ["One", "Two"])
    }

    func testDeletingRemovesOnlyThatPreset() throws {
        let s = try store()
        let keep = preset("Keep"), drop = preset("Drop")
        try s.save([keep, drop])
        let remaining = try s.delete(id: drop.id)
        XCTAssertEqual(remaining.map(\.name), ["Keep"])
    }
}
