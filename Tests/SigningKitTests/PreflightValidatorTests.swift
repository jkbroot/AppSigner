import XCTest
@testable import SigningKit

final class PreflightValidatorTests: XCTestCase {

    // MARK: Builders

    private func profile(appID: String = "TEAM123456.*",
                         expires: Date = .distantFuture,
                         certs: [String] = ["AAAA"],
                         devices: [String] = ["UDID-1"],
                         entitlements: [String: Any] = ["application-identifier": "TEAM123456.*"])
    -> ProvisioningProfile {
        ProvisioningProfile(name: "P", teamIdentifier: "TEAM123456", applicationIdentifier: appID,
                            developerCertificateSHA1s: certs, type: .adHoc, expirationDate: expires,
                            provisionedDeviceCount: devices.count, provisionedDevices: devices,
                            entitlements: entitlements)
    }

    private func report(encrypted: Bool = false,
                        archs: [String] = ["arm64"],
                        dylibs: [ResolvedDylib] = [],
                        items: [BundleItem] = []) -> BundleReport {
        let main = BinaryReport(id: "App", role: .mainExecutable, architectures: archs,
                                isEncrypted: encrypted, dylibs: dylibs)
        return BundleReport(appName: "App", bundleID: "com.x.app", version: "1.0", totalSize: 10,
                            isEncrypted: encrypted, binaries: [main], items: items, referrers: [:])
    }

    private func dylib(_ path: String, _ kind: ResolvedDylib.Kind, weak: Bool = false) -> ResolvedDylib {
        ResolvedDylib(path: path, isWeak: weak, kind: kind, resolvedRelativePath: nil)
    }

    private func run(_ input: PreflightInput) -> [String] {
        PreflightValidator().validate(input).map(\.id)
    }

    // MARK: Checks

    func testCleanSetupProducesNoErrors() {
        let findings = PreflightValidator().validate(
            PreflightInput(report: report(), profile: profile(), identitySHA1: "AAAA",
                           bundleID: "com.x.app", deviceUDID: "UDID-1"))
        XCTAssertFalse(findings.contains { $0.severity == .error }, "a valid setup has no errors")
    }

    func testFlagsEncryptedMainBinary() {
        XCTAssertTrue(run(PreflightInput(report: report(encrypted: true), profile: profile(),
                                         identitySHA1: "AAAA", bundleID: "com.x.app")).contains("encrypted"))
    }

    func testFlagsExpiredAndExpiringProfiles() {
        XCTAssertTrue(run(PreflightInput(report: report(), profile: profile(expires: .distantPast),
                                         identitySHA1: "AAAA", bundleID: "com.x.app")).contains("profileExpired"))
        let soon = Date().addingTimeInterval(10 * 24 * 3600)
        XCTAssertTrue(run(PreflightInput(report: report(), profile: profile(expires: soon),
                                         identitySHA1: "AAAA", bundleID: "com.x.app")).contains("profileExpiringSoon"))
    }

    func testFlagsIdentityNotAuthorizedByProfile() {
        XCTAssertTrue(run(PreflightInput(report: report(), profile: profile(certs: ["BBBB"]),
                                         identitySHA1: "AAAA", bundleID: "com.x.app")).contains("identityMismatch"))
    }

    func testFlagsBundleIDMismatchOnlyForNonWildcardProfiles() {
        // Wildcard profile accepts anything.
        XCTAssertFalse(run(PreflightInput(report: report(), profile: profile(appID: "TEAM123456.*"),
                                          identitySHA1: "AAAA", bundleID: "com.any.thing")).contains("bundleIDMismatch"))
        // Explicit app id must match exactly.
        XCTAssertTrue(run(PreflightInput(report: report(), profile: profile(appID: "TEAM123456.com.x.app"),
                                         identitySHA1: "AAAA", bundleID: "com.other")).contains("bundleIDMismatch"))
        XCTAssertFalse(run(PreflightInput(report: report(), profile: profile(appID: "TEAM123456.com.x.app"),
                                          identitySHA1: "AAAA", bundleID: "com.x.app")).contains("bundleIDMismatch"))
    }

    func testWarnsAboutExtensionsWithExplicitAppID() {
        let ext = BundleItem(id: "PlugIns/E.appex", name: "E.appex", kind: .appExtension,
                             sizeBytes: 1, isProtected: false, warning: nil)
        XCTAssertTrue(run(PreflightInput(report: report(items: [ext]),
                                         profile: profile(appID: "TEAM123456.com.x.app"),
                                         identitySHA1: "AAAA", bundleID: "com.x.app")).contains("extensionsNeedOwnProfiles"))
    }

    func testWarnsWhenSelectedDeviceIsNotProvisioned() {
        XCTAssertTrue(run(PreflightInput(report: report(), profile: profile(devices: ["UDID-1"]),
                                         identitySHA1: "AAAA", bundleID: "com.x.app",
                                         deviceUDID: "UDID-9")).contains("deviceNotProvisioned"))
    }

    func testSeparatesMissingStrongAndWeakDylibs() {
        let strong = run(PreflightInput(report: report(dylibs: [dylib("@rpath/M.dylib", .missing)]),
                                        profile: profile(), identitySHA1: "AAAA", bundleID: "com.x.app"))
        XCTAssertTrue(strong.contains("missingDylibs"))
        let weak = run(PreflightInput(report: report(dylibs: [dylib("@rpath/M.dylib", .missing, weak: true)]),
                                      profile: profile(), identitySHA1: "AAAA", bundleID: "com.x.app"))
        XCTAssertTrue(weak.contains("missingWeakDylibs"))
        XCTAssertFalse(weak.contains("missingDylibs"))
    }

    func testFlagsJailbreakReferencesAndMissingArm64() {
        XCTAssertTrue(run(PreflightInput(report: report(dylibs: [dylib("/Library/MobileSubstrate/X.dylib", .jailbreak)]),
                                         profile: profile(), identitySHA1: "AAAA",
                                         bundleID: "com.x.app")).contains("jailbreakReferences"))
        XCTAssertTrue(run(PreflightInput(report: report(archs: ["x86_64"]), profile: profile(),
                                         identitySHA1: "AAAA", bundleID: "com.x.app")).contains("noArm64"))
    }

    func testReportsEntitlementsTheProfileWillDrop() {
        let original: [String: Any] = [
            "application-identifier": "OLD.com.x.app",     // always rewritten, must be ignored
            "com.apple.developer.associated-domains": ["applinks:x.com"],
            "aps-environment": "production",
        ]
        let findings = PreflightValidator().validate(
            PreflightInput(report: report(), profile: profile(), identitySHA1: "AAAA",
                           bundleID: "com.x.app", originalEntitlements: original))
        let dropped = findings.first { $0.id == "droppedEntitlements" }
        XCTAssertNotNil(dropped)
        XCTAssertTrue(dropped?.detail.contains("associated-domains") == true)
        XCTAssertFalse(dropped?.detail.contains("application-identifier") == true,
                       "rewritten keys are not reported as dropped")
    }

    func testErrorsAreSortedFirst() {
        let findings = PreflightValidator().validate(
            PreflightInput(report: report(encrypted: true, archs: ["x86_64"]),
                           profile: profile(expires: .distantPast, certs: ["BBBB"]),
                           identitySHA1: "AAAA", bundleID: "com.x.app"))
        let severities = findings.map(\.severity)
        XCTAssertEqual(severities, severities.sorted())
        XCTAssertEqual(severities.first, .error)
    }
}
