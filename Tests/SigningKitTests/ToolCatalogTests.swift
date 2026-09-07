import XCTest
@testable import SigningKit

final class ToolCatalogTests: XCTestCase {
    func testCatalogIncludesKeyTools() {
        let ids = Set(ToolCatalog.all.map { $0.id })
        XCTAssertTrue(ids.isSuperset(of: ["ideviceinstaller", "idevice_id", "codesign", "zip", "optool"]))
    }

    func testOptoolIsLinkedToGitHubAndMarkedNotUsed() {
        let optool = ToolCatalog.all.first { $0.id == "optool" }
        XCTAssertNotNil(optool)
        if case .github(let repo) = optool?.manager {
            XCTAssertEqual(repo, "alexzielenski/optool")
        } else {
            XCTFail("optool should be linked to a GitHub repo")
        }
        XCTAssertTrue(optool!.purpose.lowercased().contains("not used"))
    }

    func testStatusReflectsInstallAndUpdateState() {
        let statuses = ToolsInspector().statuses(
            findPath: { $0 == "codesign" || $0 == "ideviceinstaller" ? "/usr/bin/\($0)" : nil },
            version: { $0.id == "ideviceinstaller" ? "1.2.0" : nil },
            outdatedFormulae: ["ideviceinstaller"])

        let idi = statuses.first { $0.tool.id == "ideviceinstaller" }!
        XCTAssertTrue(idi.installed)
        XCTAssertEqual(idi.version, "1.2.0")
        XCTAssertTrue(idi.updateAvailable, "outdated + installed → update available")

        let optool = statuses.first { $0.tool.id == "optool" }!
        XCTAssertFalse(optool.installed)
        XCTAssertFalse(optool.updateAvailable, "manual tools are never flagged updatable")
    }
}
