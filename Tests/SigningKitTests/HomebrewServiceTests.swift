import XCTest
@testable import SigningKit

final class HomebrewServiceTests: XCTestCase {
    func testParsesOutdatedFormulaNames() {
        let out = "ideviceinstaller\nlibimobiledevice (1.3.0) < 1.3.1\n\n"
        XCTAssertEqual(HomebrewService.parseOutdated(out), ["ideviceinstaller", "libimobiledevice"])
    }

    func testParsesVersionFromToolOutput() {
        XCTAssertEqual(HomebrewService.parseVersion("ideviceinstaller 1.1.1"), "1.1.1")
        XCTAssertEqual(HomebrewService.parseVersion("libimobiledevice 1.3.0\nmore"), "1.3.0")
        XCTAssertNil(HomebrewService.parseVersion("no version here"))
    }

    func testInstallAndUpgradeArguments() {
        XCTAssertEqual(HomebrewService.installArguments(["ideviceinstaller"]), ["install", "ideviceinstaller"])
        XCTAssertEqual(HomebrewService.upgradeArguments(["a", "b"]), ["upgrade", "a", "b"])
    }

    func testFindsBrewInSearchPath() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let brew = dir.appendingPathComponent("brew")
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        XCTAssertEqual(HomebrewService.findBrew(searchPaths: [dir.path]), brew.path)
        XCTAssertNil(HomebrewService.findBrew(searchPaths: ["/no/such/dir"]))
    }
}
