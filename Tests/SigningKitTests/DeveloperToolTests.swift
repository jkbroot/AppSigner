import XCTest
@testable import SigningKit

final class DeveloperToolTests: XCTestCase {
    private func library() throws -> DeveloperToolLibrary {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DeveloperToolLibrary(directory: dir)
    }

    func testCatalogDescribesFlex() throws {
        let flex = try XCTUnwrap(DeveloperToolCatalog.all.first { $0.id == "flex" })
        XCTAssertEqual(flex.name, "FLEX")
        XCTAssertTrue(flex.repository.contains("FLEXTool/FLEX"))
        XCTAssertEqual(flex.license, "BSD-3-Clause")
        XCTAssertNotNil(flex.triggerHint, "the user must be told how to open it")
        XCTAssertEqual(flex.artifacts, [.framework("FLEX.framework"), .dylib("FLEXBootstrap.dylib")])
    }

    func testToolIsNotReadyWhenItsArtifactsAreMissing() throws {
        let lib = try library()
        let flex = DeveloperToolCatalog.all.first { $0.id == "flex" }!
        let status = lib.status(for: flex)
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.missing.sorted(), ["FLEX.framework", "FLEXBootstrap.dylib"])
    }

    func testToolBecomesReadyOnceEveryArtifactExists() throws {
        let lib = try library()
        let flex = DeveloperToolCatalog.all.first { $0.id == "flex" }!
        let root = lib.directory.appendingPathComponent(flex.id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("FLEX.framework"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("FLEXBootstrap.dylib"))

        let status = lib.status(for: flex)
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(status.missing.isEmpty)
    }

    func testReportsFrameworksAndDylibsSeparatelyForSigning() throws {
        let lib = try library()
        let flex = DeveloperToolCatalog.all.first { $0.id == "flex" }!
        let root = lib.directory.appendingPathComponent(flex.id)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("FLEX.framework"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("FLEXBootstrap.dylib"))

        XCTAssertEqual(lib.frameworks(for: flex).map(\.lastPathComponent), ["FLEX.framework"])
        XCTAssertEqual(lib.dylibs(for: flex).map(\.lastPathComponent), ["FLEXBootstrap.dylib"])
    }

    func testImportingCopiesArtifactsIntoTheLibrary() throws {
        let lib = try library()
        let flex = DeveloperToolCatalog.all.first { $0.id == "flex" }!
        let source = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("FLEX.framework"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("FLEXBootstrap.dylib"))

        try lib.importArtifacts(for: flex, from: source)
        XCTAssertTrue(lib.status(for: flex).isReady, "a folder of prebuilt artifacts can be adopted")
    }
}

extension DeveloperToolTests {
    func testFlexBuildRecipeTargetsIOSArm64WithoutSigning() {
        let clone = DeveloperToolBuilder.flexCloneArguments(into: URL(fileURLWithPath: "/tmp/w"))
        XCTAssertEqual(clone.first, "clone")
        XCTAssertTrue(clone.contains("https://github.com/FLEXTool/FLEX.git"))
        XCTAssertTrue(clone.contains("--depth"), "a shallow clone is enough to build")

        let build = DeveloperToolBuilder.flexBuildArguments(projectDir: URL(fileURLWithPath: "/tmp/w/FLEX"),
                                                            output: URL(fileURLWithPath: "/tmp/out"))
        XCTAssertTrue(build.contains("-sdk"))
        XCTAssertTrue(build.contains("iphoneos"))
        XCTAssertTrue(build.contains("ARCHS=arm64"))
        XCTAssertTrue(build.contains("MACH_O_TYPE=mh_dylib"), "it must be a dynamic framework to inject")
        XCTAssertTrue(build.contains("CODE_SIGNING_ALLOWED=NO"), "AppSigner re-signs it later")
    }

    func testBootstrapCompileArgumentsProduceAnInjectableDylib() {
        let args = DeveloperToolBuilder.bootstrapCompileArguments(
            source: URL(fileURLWithPath: "/tmp/b.m"),
            output: URL(fileURLWithPath: "/tmp/out/FLEXBootstrap.dylib"),
            sdkPath: "/SDK")
        XCTAssertTrue(args.contains("-dynamiclib"))
        XCTAssertTrue(args.contains("arm64"))
        XCTAssertTrue(args.contains("-isysroot"))
        XCTAssertTrue(args.contains("@executable_path/Frameworks/FLEXBootstrap.dylib"),
                      "install name must resolve inside the app bundle")
        XCTAssertTrue(args.contains("-Wl,-headerpad_max_install_names"),
                      "leave header room so the result stays injectable")
    }

    func testBootstrapSourceLooksUpFlexAtRuntime() {
        let source = DeveloperToolBuilder.bootstrapSource
        XCTAssertTrue(source.contains("NSClassFromString(@\"FLEXManager\")"),
                      "no link-time dependency on FLEX, so a missing framework cannot crash the app")
        XCTAssertTrue(source.contains("showExplorer"))
        XCTAssertTrue(source.contains("numberOfTouchesRequired"))
    }
}
