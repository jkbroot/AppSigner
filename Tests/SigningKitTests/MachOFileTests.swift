import XCTest
@testable import SigningKit

final class MachOFileTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func compile(arch: String = "arm64") throws -> URL {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("main.c")
        try Data("int main(void){return 0;}".utf8).write(to: src)
        let out = dir.appendingPathComponent("prog")
        try ProcessRunner().runThrowing("/usr/bin/clang",
            ["-arch", arch, "-Wl,-headerpad_max_install_names", "-o", out.path, src.path])
        return out
    }

    func testDetectsMachOAndRejectsOtherFiles() throws {
        let bin = try compile()
        XCTAssertTrue(MachOFile.isMachO(url: bin))
        let txt = bin.deletingLastPathComponent().appendingPathComponent("x.txt")
        try Data("hello".utf8).write(to: txt)
        XCTAssertFalse(MachOFile.isMachO(url: txt))
    }

    func testReadsArchitecturesAndEncryptionFlag() throws {
        let info = try MachOFile.read(url: try compile(arch: "arm64"))
        XCTAssertEqual(info.architectures, ["arm64"])
        XCTAssertFalse(info.isEncrypted, "a locally built binary is not FairPlay encrypted")
    }

    func testReadsFatArchitectures() throws {
        let a = try compile(arch: "arm64"), b = try compile(arch: "x86_64")
        let fat = try tempDir().appendingPathComponent("fat")
        try ProcessRunner().runThrowing("/usr/bin/lipo", ["-create", a.path, b.path, "-output", fat.path])
        let info = try MachOFile.read(url: fat)
        XCTAssertEqual(Set(info.architectures), ["arm64", "x86_64"])
    }

    func testListsSystemAndInjectedDylibReferences() throws {
        let bin = try compile()
        let before = try MachOFile.read(url: bin).dylibs
        XCTAssertTrue(before.contains { $0.path.hasPrefix("/usr/lib/") }, "should list system dylibs")

        try MachOInjector.inject(dylibPath: "@rpath/Tweak.dylib", into: bin)
        let after = try MachOFile.read(url: bin).dylibs
        let tweak = try XCTUnwrap(after.first { $0.path == "@rpath/Tweak.dylib" })
        XCTAssertFalse(tweak.isWeak, "default injection is a strong reference")
        XCTAssertEqual(after.count, before.count + 1)
    }
}
