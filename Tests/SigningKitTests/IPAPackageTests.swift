import XCTest
@testable import SigningKit

final class IPAPackageTests: XCTestCase {
    private var fm: FileManager { .default }

    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipa-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func touch(_ url: URL, _ bytes: String = "x") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }

    private func makeApp(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("Payload/My.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try touch(app.appendingPathComponent("My"))
        try touch(app.appendingPathComponent("Frameworks/Lib.dylib"))
        try touch(app.appendingPathComponent("Frameworks/Core.framework/Core"))
        try touch(app.appendingPathComponent("PlugIns/Ext.appex/Ext"))
        try touch(app.appendingPathComponent("PlugIns/Ext.appex/Frameworks/Inner.framework/Inner"))
        return app
    }

    func testLocatesAppInPayload() throws {
        let root = try tempDir()
        let app = try makeApp(in: root)
        XCTAssertEqual(try IPAPackage.locateApp(payloadParent: root).resolvingSymlinksInPath().path,
                       app.resolvingSymlinksInPath().path)
    }

    func testSignableComponentsAreInnerToOuterWithAppLast() throws {
        let root = try tempDir()
        let app = try makeApp(in: root)
        let comps = try IPAPackage.signableComponents(appURL: app)

        XCTAssertEqual(comps.last?.standardizedFileURL, app.standardizedFileURL, "the .app must be signed last")
        func idx(_ suffix: String) -> Int? { comps.firstIndex { $0.path.hasSuffix(suffix) } }
        let inner = try XCTUnwrap(idx("Inner.framework"))
        let ext   = try XCTUnwrap(idx("Ext.appex"))
        XCTAssertLessThan(inner, ext, "nested framework signs before its containing appex")
        XCTAssertNotNil(idx("Core.framework"))
        XCTAssertNotNil(idx("Lib.dylib"), "loose dylibs are signable components")
    }

    func testUnpackAndRepackRoundTrip() throws {
        let root = try tempDir()
        _ = try makeApp(in: root)
        let ipa = root.appendingPathComponent("test.ipa")
        try ProcessRunner().runThrowing("/usr/bin/zip", ["-r", "-q", "test.ipa", "Payload"], cwd: root)

        let pkg = try IPAPackage.unpack(ipa: ipa)
        defer { pkg.cleanup() }
        XCTAssertTrue(fm.fileExists(atPath: pkg.appURL.path))
        XCTAssertEqual(pkg.appURL.lastPathComponent, "My.app")

        let out = root.appendingPathComponent("out.ipa")
        try pkg.repack(to: out)
        XCTAssertTrue(fm.fileExists(atPath: out.path))
        XCTAssertGreaterThan((try fm.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0, 0)
    }
}
