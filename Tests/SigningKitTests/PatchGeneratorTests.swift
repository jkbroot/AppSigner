import XCTest
@testable import SigningKit

final class PatchGeneratorTests: XCTestCase {
    func testGeneratesABoolReturnOverride() {
        let patch = MethodPatch(className: "SecretFeature", selector: "isPremiumUnlocked", value: .boolean(true))
        let src = PatchGenerator.source(for: [patch])
        XCTAssertTrue(src.contains("#import <objc/runtime.h>"))
        XCTAssertTrue(src.contains("__attribute__((constructor))"))
        XCTAssertTrue(src.contains("patchMethod(\"SecretFeature\", @selector(isPremiumUnlocked)"))
        XCTAssertTrue(src.contains("^BOOL(__unsafe_unretained id _self){ return YES; }"))
    }

    func testGeneratesIntegerDoubleStringAndNil() {
        let src = PatchGenerator.source(for: [
            MethodPatch(className: "A", selector: "count", value: .integer(42)),
            MethodPatch(className: "B", selector: "ratio", value: .double(1.5)),
            MethodPatch(className: "C", selector: "token", value: .string("free")),
            MethodPatch(className: "D", selector: "ad", value: .null),
        ])
        XCTAssertTrue(src.contains("^NSInteger(__unsafe_unretained id _self){ return 42; }"))
        XCTAssertTrue(src.contains("^double(__unsafe_unretained id _self){ return 1.5; }"))
        XCTAssertTrue(src.contains(#"^id(__unsafe_unretained id _self){ return @"free"; }"#))
        XCTAssertTrue(src.contains("^id(__unsafe_unretained id _self){ return nil; }"))
    }

    func testEscapesStringValues() {
        let src = PatchGenerator.source(for: [
            MethodPatch(className: "X", selector: "s", value: .string("a\"b\\c"))
        ])
        XCTAssertTrue(src.contains(#"@"a\"b\\c""#), "quotes and backslashes are escaped")
    }

    func testPatchesInstanceOrClassMethod() {
        // The generated helper tries the instance method, then the class method.
        let src = PatchGenerator.source(for: [MethodPatch(className: "A", selector: "x", value: .boolean(false))])
        XCTAssertTrue(src.contains("class_getInstanceMethod"))
        XCTAssertTrue(src.contains("class_getClassMethod"))
        XCTAssertTrue(src.contains("method_setImplementation"))
    }

    func testEmptyPatchesStillCompileToAValidUnit() {
        let src = PatchGenerator.source(for: [])
        XCTAssertTrue(src.contains("__attribute__((constructor))"))
        XCTAssertFalse(src.contains("patchMethod(\""), "no patches means no patch calls")
    }

    func testRoundTripsThroughCodable() throws {
        let patches = [MethodPatch(className: "A", selector: "b", value: .string("v")),
                       MethodPatch(className: "C", selector: "d", value: .boolean(true))]
        let data = try JSONEncoder().encode(patches)
        XCTAssertEqual(try JSONDecoder().decode([MethodPatch].self, from: data), patches)
    }
}

extension PatchGeneratorTests {
    func testGeneratedSourceCompilesToAnInjectableDylib() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("AppSignerPatches.m")
        try Data(PatchGenerator.source(for: [
            MethodPatch(className: "SecretFeature", selector: "isPremiumUnlocked", value: .boolean(true)),
            MethodPatch(className: "Store", selector: "adCount", value: .integer(0)),
            MethodPatch(className: "Config", selector: "token", value: .string("pro")),
        ]).utf8).write(to: src)

        let sdk = try ProcessRunner().runThrowing("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = dir.appendingPathComponent("AppSignerPatches.dylib")
        let args = PatchDylibBuilder.compileArguments(source: src, output: out, sdkPath: sdk)
        try ProcessRunner().runThrowing("/usr/bin/xcrun", args)

        XCTAssertTrue(MachOFile.isMachO(url: out))
        XCTAssertEqual(try MachOFile.read(url: out).architectures, ["arm64"])
    }
}
