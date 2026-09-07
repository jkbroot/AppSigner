import XCTest
@testable import SigningKit

final class DeviceServiceTests: XCTestCase {
    func testParsesUDIDsOnePerLineTrimmingBlankAndWhitespace() {
        XCTAssertEqual(DeviceService.parseUDIDs("aaa\nbbb\n\n  ccc  \n"), ["aaa", "bbb", "ccc"])
        XCTAssertEqual(DeviceService.parseUDIDs(""), [])
    }

    func testInstallArgumentsWithoutUDID() {
        XCTAssertEqual(DeviceService.installArguments(ipaPath: "/x/y.ipa", udid: nil), ["-i", "/x/y.ipa"])
    }

    func testInstallArgumentsWithUDID() {
        XCTAssertEqual(DeviceService.installArguments(ipaPath: "/x/y.ipa", udid: "DEAD"),
                       ["-u", "DEAD", "-i", "/x/y.ipa"])
    }

    func testFindToolLocatesExecutableInSearchPath() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("faketool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        XCTAssertEqual(DeviceService.findTool("faketool", searchPaths: [dir.path]), tool.path)
        XCTAssertNil(DeviceService.findTool("missing", searchPaths: [dir.path]))
    }
}
