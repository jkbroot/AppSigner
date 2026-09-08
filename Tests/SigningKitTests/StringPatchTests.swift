import XCTest
@testable import SigningKit

final class StringPatchTests: XCTestCase {
    // MARK: Model

    func testCodableRoundTrip() throws {
        let patch = StringPatch(binaryPath: "Frameworks/Lib.framework/Lib",
                                original: "PREMIUM_LOCKED", replacement: "unlocked")
        let decoded = try JSONDecoder().decode(StringPatch.self,
                                               from: try JSONEncoder().encode(patch))
        XCTAssertEqual(decoded.binaryPath, patch.binaryPath)
        XCTAssertEqual(decoded.original, patch.original)
        XCTAssertEqual(decoded.replacement, patch.replacement)
    }

    func testLengthValidityUsesUTF8Bytes() {
        XCTAssertTrue(StringPatch(binaryPath: "x", original: "PREMIUM", replacement: "free").isValidLength)
        XCTAssertTrue(StringPatch(binaryPath: "x", original: "abc", replacement: "abc").isValidLength)
        XCTAssertFalse(StringPatch(binaryPath: "x", original: "abc", replacement: "abcd").isValidLength)
        // "é" is two UTF-8 bytes, so it does not fit in a one-byte slot.
        XCTAssertFalse(StringPatch(binaryPath: "x", original: "a", replacement: "é").isValidLength)
    }

    func testSummaryShowsTheTransform() {
        XCTAssertEqual(StringPatch(binaryPath: "x", original: "on", replacement: "no").summary,
                       "on → no")
    }

    // MARK: Applying to a bundle

    /// Compiles a C binary embedding `literal` to `dest` (created including parents).
    private func compileBinary(embedding literal: String, to dest: URL) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("s.c")
        try Data(#"""
        #include <stdio.h>
        int main(void){ const char *s = "\#(literal)"; printf("%s\n", s); return 0; }
        """#.utf8).write(to: src)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try ProcessRunner().runThrowing("/usr/bin/clang", ["-arch", "arm64", "-o", dest.path, src.path])
    }

    func testApplyPatchesTheTargetedBinary() throws {
        let app = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("App-\(UUID().uuidString).app")
        let binary = app.appendingPathComponent("Frameworks/Lib.framework/Lib")
        try compileBinary(embedding: "PREMIUM_LOCKED", to: binary)

        let patch = StringPatch(binaryPath: "Frameworks/Lib.framework/Lib",
                                original: "PREMIUM_LOCKED", replacement: "unlocked")
        let total = try StringPatcher.apply([patch], appURL: app)

        XCTAssertGreaterThanOrEqual(total, 1)
        XCTAssertTrue(try MachOStrings.strings(url: binary).contains("unlocked"))
    }

    func testApplyDoesNotTouchOtherBinaries() throws {
        let app = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("App-\(UUID().uuidString).app")
        let target = app.appendingPathComponent("MainExe")
        let other = app.appendingPathComponent("PlugIns/Ext.appex/Ext")
        try compileBinary(embedding: "SHARED_FLAG", to: target)
        try compileBinary(embedding: "SHARED_FLAG", to: other)

        try StringPatcher.apply([StringPatch(binaryPath: "MainExe",
                                             original: "SHARED_FLAG", replacement: "off")], appURL: app)

        XCTAssertTrue(try MachOStrings.strings(url: target).contains("off"))
        XCTAssertTrue(try MachOStrings.strings(url: other).contains("SHARED_FLAG"),
                      "a patch must only touch its targeted binary")
    }
}
