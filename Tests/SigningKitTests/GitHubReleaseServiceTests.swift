import XCTest
@testable import SigningKit

final class GitHubReleaseServiceTests: XCTestCase {
    func testParsesLatestReleaseTagAndAssets() throws {
        let json = """
        {"tag_name":"0.1","assets":[
          {"name":"optool.zip","browser_download_url":"https://example.com/optool.zip","size":109096}
        ]}
        """.data(using: .utf8)!
        let release = try XCTUnwrap(GitHubReleaseService.parseLatestRelease(json))
        XCTAssertEqual(release.tag, "0.1")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "optool.zip")
        XCTAssertEqual(release.assets.first?.size, 109096)
    }

    func testPicksZipAssetContainingToolName() throws {
        let release = GitHubReleaseService.Release(tag: "0.1", assets: [
            .init(name: "source.zip", downloadURL: URL(string: "https://x/source.zip")!, size: 1),
            .init(name: "optool.zip", downloadURL: URL(string: "https://x/optool.zip")!, size: 2),
        ])
        XCTAssertEqual(GitHubReleaseService.pickBinaryAsset(release, named: "optool")?.name, "optool.zip")
    }

    func testPrefersExactlyNamedAsset() throws {
        let release = GitHubReleaseService.Release(tag: "1", assets: [
            .init(name: "optool.zip", downloadURL: URL(string: "https://x/optool.zip")!, size: 1),
            .init(name: "optool", downloadURL: URL(string: "https://x/optool")!, size: 2),
        ])
        XCTAssertEqual(GitHubReleaseService.pickBinaryAsset(release, named: "optool")?.name, "optool")
    }

    func testExtractsBinaryFromZipAsset() throws {
        // Build a zip containing a file named "optool".
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("BINARY-BYTES".utf8).write(to: dir.appendingPathComponent("optool"))
        try ProcessRunner().runThrowing("/usr/bin/zip", ["-q", "optool.zip", "optool"], cwd: dir)
        let zipData = try Data(contentsOf: dir.appendingPathComponent("optool.zip"))

        let extracted = try GitHubReleaseService().extractBinary(named: "optool", assetName: "optool.zip", data: zipData)
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "BINARY-BYTES")
    }

    /// Live GitHub fetch — gated so the default suite stays offline.
    func testFetchesLatestOptoolReleaseLive() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_NET"] == "1" else {
            throw XCTSkip("set APPSIGNER_NET=1 to run the live GitHub fetch")
        }
        let release = try GitHubReleaseService().fetchLatest(repo: "alexzielenski/optool")
        XCTAssertFalse(release.tag.isEmpty)
        XCTAssertNotNil(GitHubReleaseService.pickBinaryAsset(release, named: "optool"))
    }
}

extension GitHubReleaseServiceTests {
    /// Full chain against the real optool release. Gated by APPSIGNER_NET=1.
    func testDownloadsAndExtractsRealOptoolLive() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_NET"] == "1" else {
            throw XCTSkip("set APPSIGNER_NET=1 to run the live optool download")
        }
        let svc = GitHubReleaseService()
        let release = try svc.fetchLatest(repo: "alexzielenski/optool")
        let asset = try XCTUnwrap(GitHubReleaseService.pickBinaryAsset(release, named: "optool"))
        let data = try svc.download(asset.downloadURL)
        let binary = try svc.extractBinary(named: "optool", assetName: asset.name, data: data)
        // optool 0.1 is a 388624-byte Mach-O; check it's a Mach-O (magic) and non-trivial.
        XCTAssertGreaterThan(binary.count, 100_000)
        let magic = [UInt8](binary.prefix(4))
        XCTAssertTrue([0xCF, 0xFE, 0xCA].contains(magic.first ?? 0), "expected a Mach-O magic byte, got \(magic)")
    }
}
