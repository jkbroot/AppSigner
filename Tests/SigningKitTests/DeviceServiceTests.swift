import XCTest
@testable import SigningKit

final class DeviceServiceTests: XCTestCase {
    func testParsesUDIDsOnePerLineTrimmingBlankAndWhitespace() {
        XCTAssertEqual(DeviceService.parseUDIDs("aaa\nbbb\n\n  ccc  \n"), ["aaa", "bbb", "ccc"])
        XCTAssertEqual(DeviceService.parseUDIDs(""), [])
    }

    /// ideviceinstaller 1.2.0+ takes the package as an `install PATH` subcommand.
    func testInstallArgumentsUseInstallSubcommandWithoutUDID() {
        XCTAssertEqual(DeviceService.installArguments(ipaPath: "/x/y.ipa", udid: nil), ["install", "/x/y.ipa"])
    }

    func testInstallArgumentsUseInstallSubcommandWithUDID() {
        XCTAssertEqual(DeviceService.installArguments(ipaPath: "/x/y.ipa", udid: "DEAD"),
                       ["-u", "DEAD", "install", "/x/y.ipa"])
    }

    /// ideviceinstaller up to 1.1.x only understands the legacy `-i` flag.
    func testInstallArgumentsKeepLegacyFlagForOldCLI() {
        XCTAssertEqual(DeviceService.installArguments(ipaPath: "/x/y.ipa", udid: nil, cli: .legacyFlag),
                       ["-i", "/x/y.ipa"])
        XCTAssertEqual(DeviceService.installArguments(ipaPath: "/x/y.ipa", udid: "DEAD", cli: .legacyFlag),
                       ["-u", "DEAD", "-i", "/x/y.ipa"])
    }

    func testInstallArgumentsPassPathsWithSpacesAsSingleArgument() {
        let path = "/Users/me/My Apps/Signed App.ipa"
        XCTAssertEqual(DeviceService.installArguments(ipaPath: path, udid: "DEAD"),
                       ["-u", "DEAD", "install", path])
        XCTAssertEqual(DeviceService.installArguments(ipaPath: path, udid: "DEAD", cli: .legacyFlag),
                       ["-u", "DEAD", "-i", path])
    }

    func testInstallCLIDetectedFromHelpOutput() {
        let modern = """
        Usage: ideviceinstaller OPTIONS
          install PATH        Install app from package file specified by PATH.
          uninstall BUNDLEID  Uninstall app specified by BUNDLEID.
          -u, --udid UDID     Target specific device by UDID
        """
        let legacy = """
        Usage: ideviceinstaller OPTIONS
          -u, --udid UDID\tTarget specific device by UDID.
          -i, --install ARCHIVE\tInstall app from package file specified by ARCHIVE.
        """
        XCTAssertEqual(DeviceService.installCLI(helpOutput: modern), .subcommand)
        XCTAssertEqual(DeviceService.installCLI(helpOutput: legacy), .legacyFlag)
    }

    /// Live check against the installed tool: its help must select the argument
    /// form it accepts. A usage error (exit 2 / "invalid option") means a mismatch.
    func testGeneratedArgumentsAreAcceptedByInstalledTool() throws {
        guard let installer = DeviceService.findTool("ideviceinstaller") else {
            throw XCTSkip("ideviceinstaller is not installed")
        }
        let runner = ProcessRunner()
        let help = try runner.run(installer, ["--help"])
        let args = DeviceService.installArguments(ipaPath: "/tmp/AppSigner-missing.ipa", udid: "DEAD",
                                                  cli: DeviceService.installCLI(helpOutput: help.stdout + help.stderr))
        let result = try runner.run(installer, args)
        XCTAssertNotEqual(result.exitCode, 2, "CLI rejected \(args): \(result.stderr)")
        XCTAssertFalse((result.stdout + result.stderr).contains("invalid option"), "\(result.stderr)")
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
