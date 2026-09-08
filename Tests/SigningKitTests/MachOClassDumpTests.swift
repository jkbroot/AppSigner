import XCTest
@testable import SigningKit

final class MachOClassDumpTests: XCTestCase {
    /// Compiles a small Objective-C binary with known classes and methods.
    private func compileObjC(arch: String = "arm64") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("d.m")
        try Data("""
        #import <Foundation/Foundation.h>
        @interface SecretFeature : NSObject
        @property (nonatomic) BOOL isPremiumUnlocked;
        - (void)enableHiddenMode;
        + (NSString *)debugToken;
        @end
        @implementation SecretFeature
        - (void)enableHiddenMode {}
        + (NSString *)debugToken { return @"x"; }
        @end
        @interface AnalyticsTracker : NSObject
        - (void)flush;
        @end
        @implementation AnalyticsTracker
        - (void)flush {}
        @end
        int main(){ [SecretFeature new]; [AnalyticsTracker new]; return 0; }
        """.utf8).write(to: src)
        let sdk = try ProcessRunner().runThrowing("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = dir.appendingPathComponent("prog")
        try ProcessRunner().runThrowing("/usr/bin/xcrun",
            ["-sdk", "iphoneos", "clang", "-arch", arch, "-isysroot", sdk,
             "-mios-version-min=13.0", "-framework", "Foundation", "-o", out.path, src.path])
        return out
    }

    func testExtractsObjectiveCClassNames() throws {
        let names = try MachOClassDump.classNames(url: try compileObjC())
        XCTAssertTrue(names.contains("SecretFeature"))
        XCTAssertTrue(names.contains("AnalyticsTracker"))
    }

    func testExtractsSelectorNames() throws {
        let selectors = try MachOClassDump.selectorNames(url: try compileObjC())
        XCTAssertTrue(selectors.contains("enableHiddenMode"))
        XCTAssertTrue(selectors.contains("debugToken"))
        XCTAssertTrue(selectors.contains("setIsPremiumUnlocked:"))
        XCTAssertTrue(selectors.contains("flush"))
    }

    func testWorksOnAFatBinary() throws {
        let a = try compileObjC(arch: "arm64")
        // A single-slice fat wrapper still has to resolve the arm64 slice.
        let fat = a.deletingLastPathComponent().appendingPathComponent("fat")
        try ProcessRunner().runThrowing("/usr/bin/lipo", ["-create", a.path, "-output", fat.path])
        XCTAssertTrue(try MachOClassDump.classNames(url: fat).contains("SecretFeature"))
    }

    func testFiltersOutPunctuationNoise() throws {
        let names = try MachOClassDump.classNames(url: try compileObjC())
        XCTAssertFalse(names.contains(","))
        XCTAssertFalse(names.contains("."))
        XCTAssertTrue(names.allSatisfy { $0.count >= 2 })
    }

    func testReturnsEmptyForABinaryWithoutObjC() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("c.c")
        try Data("int main(void){return 0;}".utf8).write(to: src)
        let out = dir.appendingPathComponent("plain")
        try ProcessRunner().runThrowing("/usr/bin/clang", ["-o", out.path, src.path])
        XCTAssertTrue(try MachOClassDump.classNames(url: out).isEmpty)
    }

    func testAnalyzeSummarisesCountsAndIsSearchable() throws {
        let report = try MachOClassDump.analyze(url: try compileObjC())
        XCTAssertGreaterThanOrEqual(report.classNames.count, 2)
        XCTAssertFalse(report.selectorNames.isEmpty)
        XCTAssertTrue(report.classNames.contains("SecretFeature"))
        // Names are sorted and de-duplicated for display.
        XCTAssertEqual(report.classNames, report.classNames.sorted())
    }
}

extension MachOClassDumpTests {
    /// Proves extraction works on a real, chained-fixups App Store binary. Gated.
    func testDumpsClassesFromARealAppBinary() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1")
        }
        let ipa = try XCTUnwrap(Fixtures.sourceIPAs().first)
        let pkg = try IPAPackage.unpack(ipa: ipa)
        defer { pkg.cleanup() }
        let exe = try XCTUnwrap(try InfoPlistEditor(url: pkg.appURL.appendingPathComponent("Info.plist"))
            .string(forKey: "CFBundleExecutable"))
        let report = try MachOClassDump.analyze(url: pkg.appURL.appendingPathComponent(exe))
        print("real binary: \(report.classNames.count) classes, \(report.selectorNames.count) selectors")
        print("sample classes: \(report.classNames.prefix(8).joined(separator: ", "))")
        print("'unlock'/'premium' matches: "
              + report.classNames.filter { $0.lowercased().contains("premium") || $0.lowercased().contains("unlock") }.prefix(6).joined(separator: ", "))
        XCTAssertGreaterThan(report.classNames.count, 100, "a real app defines many classes")
        XCTAssertGreaterThan(report.selectorNames.count, 100)
    }
}
