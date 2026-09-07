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
