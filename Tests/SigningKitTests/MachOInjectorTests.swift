import XCTest
@testable import SigningKit

final class MachOInjectorTests: XCTestCase {

    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macho-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Compiles a tiny Mach-O executable for the given arch.
    /// Real injectable app binaries reserve header padding (`-headerpad_max_install_names`);
    /// pass `headerPad: false` to build a worst-case binary with no injection slack.
    private func compile(arch: String, headerPad: Bool = true) throws -> URL {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("main.c")
        try Data("int main(void){return 0;}".utf8).write(to: src)
        let out = dir.appendingPathComponent("prog_\(arch)")
        var args = ["-arch", arch, "-o", out.path, src.path]
        if headerPad { args += ["-Wl,-headerpad_max_install_names"] }
        try ProcessRunner().runThrowing("/usr/bin/clang", args)
        return out
    }

    private func otoolL(_ url: URL) throws -> String {
        try ProcessRunner().run("/usr/bin/otool", ["-L", url.path]).stdout
    }

    func testInjectsDylibIntoThinArm64() throws {
        let bin = try compile(arch: "arm64")
        XCTAssertFalse(try otoolL(bin).contains("@executable_path/Injected.dylib"))
        try MachOInjector.inject(dylibPath: "@executable_path/Injected.dylib", into: bin)
        XCTAssertTrue(try otoolL(bin).contains("@executable_path/Injected.dylib"),
                      "otool -L should list the injected dylib")
    }

    func testInjectedBinaryStillValidMachO() throws {
        let bin = try compile(arch: "arm64")
        try MachOInjector.inject(dylibPath: "@executable_path/Foo.dylib", into: bin)
        // otool -l must parse the header cleanly and show the new load command
        let r = try ProcessRunner().run("/usr/bin/otool", ["-l", bin.path])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("LC_LOAD_DYLIB"))
        XCTAssertTrue(r.stdout.contains("@executable_path/Foo.dylib"))
    }

    func testInjectsIntoFatBinary() throws {
        let a = try compile(arch: "arm64")
        let b = try compile(arch: "x86_64")
        let fat = try tempDir().appendingPathComponent("fatprog")
        try ProcessRunner().runThrowing("/usr/bin/lipo", ["-create", a.path, b.path, "-output", fat.path])
        try MachOInjector.inject(dylibPath: "@executable_path/Injected.dylib", into: fat)
        XCTAssertTrue(try otoolL(fat).contains("@executable_path/Injected.dylib"))
    }

    func testRejectsNonMachO() throws {
        let f = try tempDir().appendingPathComponent("notmacho.txt")
        try Data("hello world".utf8).write(to: f)
        XCTAssertThrowsError(try MachOInjector.inject(dylibPath: "@executable_path/X.dylib", into: f))
    }

    func testThrowsNoHeaderSpaceWhenNoPadding() throws {
        let bin = try compile(arch: "arm64", headerPad: false)
        XCTAssertThrowsError(try MachOInjector.inject(dylibPath: "@executable_path/X.dylib", into: bin)) { error in
            XCTAssertEqual(error as? MachOInjector.InjectError, .noHeaderSpace)
        }
    }
}

extension MachOInjectorTests {
    private func compilePadded(_ arch: String = "arm64") throws -> URL {
        try compile(arch: arch, headerPad: true)
    }

    func testInjectsWeakDylib() throws {
        let bin = try compilePadded()
        try MachOInjector.inject(dylibPath: "@rpath/Weak.dylib", into: bin, weak: true)
        let ref = try XCTUnwrap(MachOFile.read(url: bin).dylibs.first { $0.path == "@rpath/Weak.dylib" })
        XCTAssertTrue(ref.isWeak)
        XCTAssertTrue(try ProcessRunner().run("/usr/bin/otool", ["-L", bin.path]).stdout.contains("weak"))
    }

    func testRemovesDylibLeavingOthersIntact() throws {
        let bin = try compilePadded()
        try MachOInjector.inject(dylibPath: "@rpath/A.dylib", into: bin)
        try MachOInjector.inject(dylibPath: "@rpath/B.dylib", into: bin)
        let before = try MachOFile.read(url: bin).dylibs.count

        try MachOInjector.removeDylib(path: "@rpath/A.dylib", from: bin)

        let after = try MachOFile.read(url: bin).dylibs
        XCTAssertFalse(after.contains { $0.path == "@rpath/A.dylib" }, "removed reference is gone")
        XCTAssertTrue(after.contains { $0.path == "@rpath/B.dylib" }, "other injected dylib survives")
        XCTAssertTrue(after.contains { $0.path.hasPrefix("/usr/lib/") }, "system dylibs survive")
        XCTAssertEqual(after.count, before - 1)
        // The binary must still parse cleanly.
        XCTAssertEqual(try ProcessRunner().run("/usr/bin/otool", ["-l", bin.path]).exitCode, 0)
    }

    func testSetWeakTogglesReference() throws {
        let bin = try compilePadded()
        try MachOInjector.inject(dylibPath: "@rpath/T.dylib", into: bin, weak: false)
        XCTAssertFalse(try XCTUnwrap(MachOFile.read(url: bin).dylibs.first { $0.path == "@rpath/T.dylib" }).isWeak)

        try MachOInjector.setWeak(true, forDylib: "@rpath/T.dylib", in: bin)
        XCTAssertTrue(try XCTUnwrap(MachOFile.read(url: bin).dylibs.first { $0.path == "@rpath/T.dylib" }).isWeak)

        try MachOInjector.setWeak(false, forDylib: "@rpath/T.dylib", in: bin)
        XCTAssertFalse(try XCTUnwrap(MachOFile.read(url: bin).dylibs.first { $0.path == "@rpath/T.dylib" }).isWeak)
    }

    func testRemoveThrowsWhenDylibNotPresent() throws {
        let bin = try compilePadded()
        XCTAssertThrowsError(try MachOInjector.removeDylib(path: "@rpath/Nope.dylib", from: bin)) { error in
            XCTAssertEqual(error as? MachOInjector.InjectError, .dylibNotFound)
        }
    }

    func testRemovalAppliesToEverySliceOfAFatBinary() throws {
        let a = try compilePadded("arm64"), b = try compilePadded("x86_64")
        let fat = a.deletingLastPathComponent().appendingPathComponent("fatprog")
        try ProcessRunner().runThrowing("/usr/bin/lipo", ["-create", a.path, b.path, "-output", fat.path])
        try MachOInjector.inject(dylibPath: "@rpath/F.dylib", into: fat)
        XCTAssertTrue(try MachOFile.read(url: fat).dylibs.contains { $0.path == "@rpath/F.dylib" })

        try MachOInjector.removeDylib(path: "@rpath/F.dylib", from: fat)
        XCTAssertFalse(try ProcessRunner().run("/usr/bin/otool", ["-L", fat.path]).stdout.contains("@rpath/F.dylib"),
                       "gone from every slice")
    }
}
