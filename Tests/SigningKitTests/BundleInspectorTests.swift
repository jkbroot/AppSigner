import XCTest
@testable import SigningKit

final class BundleInspectorTests: XCTestCase {
    private var fm: FileManager { .default }

    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bi-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func machO(at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("s.c")
        try Data("int main(void){return 0;}".utf8).write(to: src)
        try ProcessRunner().runThrowing("/usr/bin/clang",
            ["-Wl,-headerpad_max_install_names", "-o", url.path, src.path])
        try? fm.removeItem(at: src)
    }

    private func file(_ url: URL, _ bytes: Int = 32) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A generic app bundle covering every structure kind we classify.
    private func makeApp() throws -> URL {
        let app = try tempDir().appendingPathComponent("Demo.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "Demo", "CFBundleIdentifier": "com.demo.app",
                                   "CFBundleShortVersionString": "2.0", "CFBundleName": "Demo"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))

        try machO(at: app.appendingPathComponent("Demo"))
        try machO(at: app.appendingPathComponent("Frameworks/Lib.dylib"))
        try machO(at: app.appendingPathComponent("Frameworks/Core.framework/Core"))
        try machO(at: app.appendingPathComponent("PlugIns/Ext.appex/Ext"))
        try machO(at: app.appendingPathComponent("Extensions/Legacy.appex/Legacy"))
        try file(app.appendingPathComponent("PlugIns/Ext.appex/Info.plist"))
        try file(app.appendingPathComponent("Watch/W.app/Info.plist"))
        try file(app.appendingPathComponent("Assets.car"), 5000)
        try file(app.appendingPathComponent("Res.bundle/data.bin"), 1000)
        try file(app.appendingPathComponent("en.lproj/Localizable.strings"))
        try file(app.appendingPathComponent("SC_Info/Demo.sinf"))
        try file(app.appendingPathComponent("PkgInfo"), 8)

        // One resolvable reference and one dangling reference.
        try MachOInjector.inject(dylibPath: "@rpath/Lib.dylib", into: app.appendingPathComponent("Demo"), weak: true)
        try MachOInjector.inject(dylibPath: "@rpath/Missing.dylib", into: app.appendingPathComponent("Demo"))
        return app
    }

    func testReadsAppMetadata() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        XCTAssertEqual(report.bundleID, "com.demo.app")
        XCTAssertEqual(report.version, "2.0")
        XCTAssertFalse(report.isEncrypted)
        XCTAssertGreaterThan(report.totalSize, 0)
    }

    func testDiscoversEveryMachOBinaryWithItsRole() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        let byPath = Dictionary(uniqueKeysWithValues: report.binaries.map { ($0.id, $0.role) })
        XCTAssertEqual(byPath["Demo"], .mainExecutable)
        XCTAssertEqual(byPath["Frameworks/Lib.dylib"], .dylib)
        XCTAssertEqual(byPath["Frameworks/Core.framework/Core"], .framework)
        XCTAssertEqual(byPath["PlugIns/Ext.appex/Ext"], .appExtension)
    }

    func testClassifiesDylibReferences() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        let main = try XCTUnwrap(report.binaries.first { $0.role == .mainExecutable })

        let bundled = try XCTUnwrap(main.dylibs.first { $0.path == "@rpath/Lib.dylib" })
        XCTAssertEqual(bundled.kind, .bundled)
        XCTAssertEqual(bundled.resolvedRelativePath, "Frameworks/Lib.dylib")
        XCTAssertTrue(bundled.isWeak)

        XCTAssertEqual(main.dylibs.first { $0.path == "@rpath/Missing.dylib" }?.kind, .missing)
        XCTAssertTrue(main.dylibs.contains { $0.kind == .system }, "system dylibs are classified")
    }

    func testClassifiesRemovableItemsAndProtectsCriticalOnes() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        let kinds = Dictionary(grouping: report.items, by: { $0.kind }).mapValues { $0.map(\.name) }

        XCTAssertEqual(Set(kinds[.appExtension] ?? []), ["Ext.appex", "Legacy.appex"],
                       "extensions live in PlugIns/ or Extensions/ depending on the app")
        XCTAssertEqual(kinds[.watchApp], ["W.app"])
        XCTAssertTrue(kinds[.framework]?.contains("Core.framework") == true)
        XCTAssertTrue(kinds[.dylib]?.contains("Lib.dylib") == true)
        XCTAssertTrue(kinds[.resourceBundle]?.contains("Res.bundle") == true)
        XCTAssertTrue(kinds[.localization]?.contains("en.lproj") == true)
        XCTAssertTrue(kinds[.fairplayLeftover]?.contains("SC_Info") == true)

        // Critical files must never be offered for removal.
        let protectedNames = Set(report.items.filter(\.isProtected).map(\.name))
        XCTAssertTrue(protectedNames.isSuperset(of: ["Demo", "Info.plist"]))
        XCTAssertTrue(report.items.first { $0.name == "Assets.car" }?.warning != nil,
                      "removing the asset catalog should warn")
    }

    func testBuildsReferrerGraphForBundledDylibs() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        XCTAssertEqual(report.referrers["Frameworks/Lib.dylib"], ["Demo"])
    }

    func testItemsAreSortedBySizeDescending() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        let sizes = report.items.map(\.sizeBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }
}

extension BundleInspectorTests {
    /// Validates the generic scanner against a real, complex app. Gated by APPSIGNER_INTEGRATION=1.
    func testInspectsRealAppGenerically() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1 to inspect a real IPA")
        }
        let ipa = try XCTUnwrap(Fixtures.sourceIPAs().first, "no source .ipa in the workspace")
        let pkg = try IPAPackage.unpack(ipa: ipa)
        defer { pkg.cleanup() }

        let report = try BundleInspector().inspect(appURL: pkg.appURL)
        print("app=\(report.appName) id=\(report.bundleID) v=\(report.version) "
              + "size=\(report.totalSize / 1_000_000)MB encrypted=\(report.isEncrypted)")
        print("binaries=\(report.binaries.count) items=\(report.items.count)")
        let main = try XCTUnwrap(report.binaries.first { $0.role == .mainExecutable })
        let bundled = main.dylibs.filter { $0.kind == .bundled }
        print("main arch=\(main.architectures) bundled dylibs=\(bundled.count) "
              + "weak=\(bundled.filter(\.isWeak).count) missing=\(main.dylibs.filter { $0.kind == .missing }.count)")
        print("top items: " + report.items.prefix(5)
            .map { "\($0.name)(\($0.kind.rawValue), \($0.sizeBytes / 1_000_000)MB)" }.joined(separator: ", "))

        XCTAssertFalse(report.bundleID.isEmpty)
        XCTAssertGreaterThan(report.totalSize, 0)
        XCTAssertFalse(report.binaries.isEmpty, "must discover Mach-O binaries")
        XCTAssertTrue(main.dylibs.contains { $0.kind == .system }, "system refs classified")
        XCTAssertTrue(report.items.allSatisfy { !$0.name.isEmpty })
    }
}

extension BundleInspectorTests {
    func testEncryptionFlagReflectsTheMainExecutable() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        let main = try XCTUnwrap(report.binaries.first { $0.role == .mainExecutable })
        XCTAssertEqual(report.isEncrypted, main.isEncrypted,
                       "the bundle-level flag is the main executable's, not any nested binary's")
    }

    func testDiscoversExtensionBinaryInEitherContainer() throws {
        let report = try BundleInspector().inspect(appURL: try makeApp())
        let roles = Dictionary(uniqueKeysWithValues: report.binaries.map { ($0.id, $0.role) })
        XCTAssertEqual(roles["PlugIns/Ext.appex/Ext"], .appExtension)
        XCTAssertEqual(roles["Extensions/Legacy.appex/Legacy"], .appExtension)
    }
}

extension BundleInspectorTests {
    func testReportsBundleIDsForNestedBundles() throws {
        let app = try makeApp()
        // Give the extension its own identifier, as a real appex has.
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.demo.app.share", "CFBundleExecutable": "Ext"],
            format: .xml, options: 0)
            .write(to: app.appendingPathComponent("PlugIns/Ext.appex/Info.plist"))

        let report = try BundleInspector().inspect(appURL: app)
        let ext = try XCTUnwrap(report.items.first { $0.name == "Ext.appex" })
        XCTAssertEqual(ext.bundleID, "com.demo.app.share")
        XCTAssertNil(report.items.first { $0.name == "Assets.car" }?.bundleID,
                     "plain files have no bundle id")
    }
}
