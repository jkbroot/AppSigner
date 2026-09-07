import XCTest
@testable import SigningKit

final class BundleEditorTests: XCTestCase {
    private var fm: FileManager { .default }

    private func machO(at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let src = url.deletingLastPathComponent().appendingPathComponent("s.c")
        try Data("int main(void){return 0;}".utf8).write(to: src)
        try ProcessRunner().runThrowing("/usr/bin/clang",
            ["-Wl,-headerpad_max_install_names", "-o", url.path, src.path])
        try? fm.removeItem(at: src)
    }

    private func makeApp() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("be-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Demo.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Demo", "CFBundleIdentifier": "com.demo"],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try machO(at: app.appendingPathComponent("Demo"))
        try machO(at: app.appendingPathComponent("PlugIns/Ext.appex/Ext"))
        try machO(at: app.appendingPathComponent("Frameworks/Keep.dylib"))
        try MachOInjector.inject(dylibPath: "@rpath/Drop.dylib", into: app.appendingPathComponent("Demo"))
        try MachOInjector.inject(dylibPath: "@rpath/Keep.dylib", into: app.appendingPathComponent("Demo"))
        try MachOInjector.inject(dylibPath: "@rpath/Drop.dylib", into: app.appendingPathComponent("PlugIns/Ext.appex/Ext"))
        return app
    }

    private func dylibs(_ url: URL) throws -> [String] {
        try MachOFile.read(url: url).dylibs.map(\.path)
    }

    func testRemovesBundleFilesAndDirectories() throws {
        let app = try makeApp()
        var edits = BundleEdits(); edits.removedPaths = ["PlugIns/Ext.appex", "Frameworks/Keep.dylib"]
        try BundleEditor().apply(edits, to: app)
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("PlugIns/Ext.appex").path))
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("Frameworks/Keep.dylib").path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("Demo").path))
    }

    func testStripsDylibOnlyFromTheTargetedBinary() throws {
        let app = try makeApp()
        var edits = BundleEdits()
        edits.removedDylibs = [DylibEdit(binaryPath: "Demo", dylibPath: "@rpath/Drop.dylib")]
        try BundleEditor().apply(edits, to: app)

        XCTAssertFalse(try dylibs(app.appendingPathComponent("Demo")).contains("@rpath/Drop.dylib"))
        XCTAssertTrue(try dylibs(app.appendingPathComponent("Demo")).contains("@rpath/Keep.dylib"))
        XCTAssertTrue(try dylibs(app.appendingPathComponent("PlugIns/Ext.appex/Ext")).contains("@rpath/Drop.dylib"),
                      "other binaries are untouched")
    }

    func testWeakensSelectedReference() throws {
        let app = try makeApp()
        var edits = BundleEdits()
        edits.weakenedDylibs = [DylibEdit(binaryPath: "Demo", dylibPath: "@rpath/Keep.dylib")]
        try BundleEditor().apply(edits, to: app)
        let ref = try XCTUnwrap(MachOFile.read(url: app.appendingPathComponent("Demo"))
            .dylibs.first { $0.path == "@rpath/Keep.dylib" })
        XCTAssertTrue(ref.isWeak)
    }

    func testRefusesToDeleteProtectedPaths() throws {
        let app = try makeApp()
        for path in ["Info.plist", "Demo", "_CodeSignature"] {
            var edits = BundleEdits(); edits.removedPaths = [path]
            XCTAssertThrowsError(try BundleEditor().apply(edits, to: app), "must protect \(path)") { error in
                XCTAssertEqual(error as? BundleEditor.EditError, .protectedPath(path))
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("Info.plist").path))
    }

    func testRefusesPathsEscapingTheBundle() throws {
        let app = try makeApp()
        var edits = BundleEdits(); edits.removedPaths = ["../outside.txt"]
        XCTAssertThrowsError(try BundleEditor().apply(edits, to: app)) { error in
            XCTAssertEqual(error as? BundleEditor.EditError, .invalidPath("../outside.txt"))
        }
    }

    func testEmptyEditsChangeNothing() throws {
        let app = try makeApp()
        let before = try dylibs(app.appendingPathComponent("Demo"))
        try BundleEditor().apply(BundleEdits(), to: app)
        XCTAssertEqual(try dylibs(app.appendingPathComponent("Demo")), before)
    }
}
