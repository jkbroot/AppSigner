import XCTest
@testable import SigningKit

final class MachOStringsTests: XCTestCase {
    /// Compiles a small binary whose `__cstring` section holds known string literals.
    /// The literals are printed so the linker cannot dead-strip them.
    @discardableResult
    private func compile(_ body: String = #"""
        #include <stdio.h>
        int main(void){
            const char *api  = "https://api.example.com/v1/secret";
            const char *flag = "PREMIUM_LOCKED";
            printf("%s %s\n", api, flag);
            return 0;
        }
        """#, arches: [String] = ["arm64"]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("str-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("s.c")
        try Data(body.utf8).write(to: src)
        let out = dir.appendingPathComponent("prog")
        var args = ["-o", out.path]
        for arch in arches { args += ["-arch", arch] }
        args.append(src.path)
        try ProcessRunner().runThrowing("/usr/bin/clang", args)
        return out
    }

    func testReadsCStringLiterals() throws {
        let strings = try MachOStrings.strings(url: try compile())
        XCTAssertTrue(strings.contains("https://api.example.com/v1/secret"))
        XCTAssertTrue(strings.contains("PREMIUM_LOCKED"))
    }

    func testReplacesAShorterStringInPlace() throws {
        let url = try compile()
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        let count = try MachOStrings.replace("PREMIUM_LOCKED", with: "unlocked", in: url)
        XCTAssertGreaterThanOrEqual(count, 1)

        let strings = try MachOStrings.strings(url: url)
        XCTAssertTrue(strings.contains("unlocked"))
        XCTAssertFalse(strings.contains("PREMIUM_LOCKED"))
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(sizeBefore, sizeAfter, "an in-place edit must not change the file size")
    }

    func testRejectsALongerReplacement() throws {
        let url = try compile()
        XCTAssertThrowsError(try MachOStrings.replace("PREMIUM_LOCKED",
                                                      with: "this_replacement_is_far_too_long_to_fit", in: url)) {
            XCTAssertEqual($0 as? MachOStrings.StringEditError,
                           .tooLong(original: 14, replacement: 39))
        }
        XCTAssertTrue(try MachOStrings.strings(url: url).contains("PREMIUM_LOCKED"),
                      "a rejected edit must leave the binary untouched")
    }

    func testThrowsWhenOriginalMissing() throws {
        let url = try compile()
        XCTAssertThrowsError(try MachOStrings.replace("DOES_NOT_EXIST", with: "x", in: url)) {
            XCTAssertEqual($0 as? MachOStrings.StringEditError, .notFound("DOES_NOT_EXIST"))
        }
    }

    func testPatchesEverySliceOfAUniversalBinary() throws {
        let url = try compile(arches: ["arm64", "x86_64"])
        let count = try MachOStrings.replace("PREMIUM_LOCKED", with: "unlocked", in: url)
        XCTAssertGreaterThanOrEqual(count, 2, "both slices of a universal binary must be patched")
        XCTAssertTrue(try MachOStrings.strings(url: url).contains("unlocked"))
    }
}
