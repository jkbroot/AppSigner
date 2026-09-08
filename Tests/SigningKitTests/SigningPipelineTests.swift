import XCTest
@testable import SigningKit

final class SigningPipelineTests: XCTestCase {
    private var repoRoot: URL { Fixtures.workspaceRoot }

    func testDefaultOutputNameDerivesFromIPABasename() {
        let ipa = URL(fileURLWithPath: "/tmp/YTKACE_21.35.3_0.9.2.ipa")
        let out = SigningPipeline.defaultOutputURL(forIPA: ipa)
        XCTAssertEqual(out.lastPathComponent, "YTKACE_21.35.3_0.9.2_Signed.ipa")
        XCTAssertEqual(out.deletingLastPathComponent().path, "/tmp")
    }

    /// End-to-end signing against a real IPA. Runs only when a real IPA + matching
    /// identity are present and APPSIGNER_INTEGRATION=1 (keeps the default suite fast).
    func testSignsRealIPAEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1 to run the end-to-end signing test")
        }
        let profileURL = repoRoot.appendingPathComponent("AppSigner.mobileprovision")
        let ipas = (try? FileManager.default.contentsOfDirectory(at: repoRoot, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ipa" && !$0.lastPathComponent.contains("_Signed") } ?? []
        let ipa = try XCTUnwrap(ipas.first, "no source .ipa present in repo root")

        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: profileURL))
        let identities = try KeychainService().listCodeSigningIdentities()
        let match = try XCTUnwrap(
            KeychainService.identities(identities, matchingCertificateSHA1s: profile.developerCertificateSHA1s).first,
            "no keychain identity matches the profile")

        let out = repoRoot.appendingPathComponent("PipelineTest_Signed.ipa")
        try? FileManager.default.removeItem(at: out)

        let result = try SigningPipeline().sign(
            SigningRequest(ipa: ipa, profileURL: profileURL, identitySHA1: match.sha1,
                           edits: InfoPlistEdits(), outputURL: out),
            progress: { print("• \($0)") })

        XCTAssertEqual(result.teamIdentifier, "224K3NKKQX")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        try Codesigner().verify(IPAPackage.unpack(ipa: result.outputURL).appURL) // throws if invalid
        try? FileManager.default.removeItem(at: out)
    }
}

extension SigningPipelineTests {
    /// End-to-end: injects a compiled dylib into a real IPA and re-signs.
    /// Gated by APPSIGNER_INTEGRATION=1 + a real IPA + a matching identity.
    func testSignsWithInjectedDylibEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1 to run the injection end-to-end test")
        }
        let profileURL = repoRoot.appendingPathComponent("AppSigner.mobileprovision")
        let ipas = (try? FileManager.default.contentsOfDirectory(at: repoRoot, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ipa" && !$0.lastPathComponent.contains("_Signed") } ?? []
        let ipa = try XCTUnwrap(ipas.first)

        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: profileURL))
        let identities = try KeychainService().listCodeSigningIdentities()
        let match = try XCTUnwrap(
            KeychainService.identities(identities, matchingCertificateSHA1s: profile.developerCertificateSHA1s).first)

        // Compile a small arm64 dylib to inject.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dylib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("t.c")
        try Data("__attribute__((constructor)) static void go(void){}".utf8).write(to: src)
        let dylib = dir.appendingPathComponent("libInjectTest.dylib")
        try ProcessRunner().runThrowing("/usr/bin/clang",
            ["-dynamiclib", "-arch", "arm64", "-install_name", "@executable_path/Frameworks/libInjectTest.dylib",
             "-o", dylib.path, src.path])

        let out = repoRoot.appendingPathComponent("InjectTest_Signed.ipa")
        try? FileManager.default.removeItem(at: out)
        let result = try SigningPipeline().sign(
            SigningRequest(ipa: ipa, profileURL: profileURL, identitySHA1: match.sha1,
                           edits: InfoPlistEdits(), dylibs: [dylib], outputURL: out),
            progress: { print("• \($0)") })

        // Inspect the signed output.
        let pkg = try IPAPackage.unpack(ipa: result.outputURL)
        defer { pkg.cleanup(); try? FileManager.default.removeItem(at: out) }
        let exe = try XCTUnwrap(try InfoPlistEditor(url: pkg.appURL.appendingPathComponent("Info.plist"))
            .string(forKey: "CFBundleExecutable"))
        let load = try ProcessRunner().run("/usr/bin/otool", ["-L", pkg.appURL.appendingPathComponent(exe).path]).stdout
        XCTAssertTrue(load.contains("@executable_path/Frameworks/libInjectTest.dylib"), "main binary should load the injected dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appURL.appendingPathComponent("Frameworks/libInjectTest.dylib").path))
        try Codesigner().verify(pkg.appURL)
    }
}

import ImageIO
import CoreGraphics

extension SigningPipelineTests {
    /// End-to-end: replaces the icon of a real IPA and re-signs. Gated by APPSIGNER_INTEGRATION=1.
    func testSignsWithReplacedIconEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1 to run the icon end-to-end test")
        }
        let profileURL = repoRoot.appendingPathComponent("AppSigner.mobileprovision")
        let ipas = (try? FileManager.default.contentsOfDirectory(at: repoRoot, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ipa" && !$0.lastPathComponent.contains("_Signed") } ?? []
        let ipa = try XCTUnwrap(ipas.first)
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: profileURL))
        let match = try XCTUnwrap(KeychainService.identities(
            try KeychainService().listCodeSigningIdentities(),
            matchingCertificateSHA1s: profile.developerCertificateSHA1s).first)

        // Source icon.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        let g = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        g.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let icon = dir.appendingPathComponent("icon.png")
        let d = CGImageDestinationCreateWithURL(icon as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, g.makeImage()!, nil); _ = CGImageDestinationFinalize(d)

        let out = repoRoot.appendingPathComponent("IconTest_Signed.ipa")
        try? FileManager.default.removeItem(at: out)
        let result = try SigningPipeline().sign(
            SigningRequest(ipa: ipa, profileURL: profileURL, identitySHA1: match.sha1,
                           iconImage: icon, outputURL: out),
            progress: { print("• \($0)") })

        // The app's ORIGINAL icon reference (often pointing into Assets.car) before signing.
        let originalInfo = try IPAPackage.readAppInfo(ipa: ipa)
        let originalPlist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: {
                let w = try IPAPackage.unpack(ipa: ipa); return w.appURL.appendingPathComponent("Info.plist")
            }()), format: nil) as? [String: Any]
        let originalBase = ((originalPlist?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"]
                            as? [String: Any])?["CFBundleIconFiles"] as? [String] ?? []
        _ = originalInfo

        let pkg = try IPAPackage.unpack(ipa: result.outputURL)
        defer { pkg.cleanup(); try? FileManager.default.removeItem(at: out) }

        // Standard AppIcon written at the right size.
        let iconURL = pkg.appURL.appendingPathComponent("AppIcon60x60@2x.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconURL.path))
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(iconURL as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 120)

        // Assets.car override: a loose PNG for the app's original icon name now exists.
        if let base = originalBase.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.appURL.appendingPathComponent("\(base)@2x.png").path),
                          "expected a loose override for the app's catalog icon '\(base)'")
        }
        try Codesigner().verify(pkg.appURL)
    }
}

extension SigningPipelineTests {
    /// End-to-end: strip an app extension and a dylib reference, then sign.
    /// Gated by APPSIGNER_INTEGRATION=1.
    func testSignsWithBundleRemovalsEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1 to run the removal end-to-end test")
        }
        let profileURL = Fixtures.profileURL
        let ipa = try XCTUnwrap(Fixtures.sourceIPAs().first)
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: profileURL))
        let match = try XCTUnwrap(KeychainService.identities(
            try KeychainService().listCodeSigningIdentities(),
            matchingCertificateSHA1s: profile.developerCertificateSHA1s).first)

        // Inspect first to choose real targets generically.
        let source = try IPAPackage.unpack(ipa: ipa)
        let report = try BundleInspector().inspect(appURL: source.appURL)
        let main = try XCTUnwrap(report.binaries.first { $0.role == .mainExecutable })
        let appex = try XCTUnwrap(report.items.first { $0.kind == .appExtension && !$0.isProtected })
        let bundledDylib = main.dylibs.first { $0.kind == .bundled && $0.path.hasSuffix(".dylib") }
        source.cleanup()

        var edits = BundleEdits()
        edits.removedPaths = [appex.id]
        if let d = bundledDylib { edits.removedDylibs = [DylibEdit(binaryPath: main.id, dylibPath: d.path)] }

        let out = Fixtures.workspaceRoot.appendingPathComponent("RemovalTest_Signed.ipa")
        try? FileManager.default.removeItem(at: out)
        let result = try SigningPipeline().sign(
            SigningRequest(ipa: ipa, profileURL: profileURL, identitySHA1: match.sha1,
                           bundleEdits: edits, outputURL: out),
            progress: { print("• \($0)") })

        let pkg = try IPAPackage.unpack(ipa: result.outputURL)
        defer { pkg.cleanup(); try? FileManager.default.removeItem(at: out) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.appURL.appendingPathComponent(appex.id).path),
                       "the removed extension is gone from the signed output")
        if let d = bundledDylib {
            let after = try MachOFile.read(url: pkg.appURL.appendingPathComponent(main.id)).dylibs
            XCTAssertFalse(after.contains { $0.path == d.path }, "the stripped dylib reference is gone")
        }
        try Codesigner().verify(pkg.appURL)   // still a valid signature
    }
}

extension SigningPipelineTests {
    /// End-to-end: rewrite a real string literal in the main binary and re-sign.
    /// Gated by APPSIGNER_INTEGRATION=1.
    func testSignsWithAStringPatchEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1")
        }
        let profileURL = Fixtures.profileURL
        let ipa = try XCTUnwrap(Fixtures.sourceIPAs().first)
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: profileURL))
        let identity = try XCTUnwrap(KeychainService.identities(
            try KeychainService().listCodeSigningIdentities(),
            matchingCertificateSHA1s: profile.developerCertificateSHA1s).first)

        // Pick a real string long enough to overwrite with our marker.
        let marker = "APPSIGNER_TEST"
        let pkg = try IPAPackage.unpack(ipa: ipa)
        let exe = try XCTUnwrap(try InfoPlistEditor(url: pkg.appURL.appendingPathComponent("Info.plist"))
            .string(forKey: "CFBundleExecutable"))
        let original = try XCTUnwrap(MachOStrings.strings(url: pkg.appURL.appendingPathComponent(exe))
            .first { $0.utf8.count >= marker.utf8.count && $0 != marker && $0.allSatisfy(\.isASCII) })
        pkg.cleanup()
        print("patching string \"\(original)\" -> \"\(marker)\"")

        let out = Fixtures.workspaceRoot.appendingPathComponent("StringPatchTest_Signed.ipa")
        try? FileManager.default.removeItem(at: out)
        let result = try SigningPipeline().sign(
            SigningRequest(ipa: ipa, profileURL: profileURL, identitySHA1: identity.sha1,
                           stringPatches: [StringPatch(binaryPath: exe, original: original, replacement: marker)],
                           outputURL: out),
            progress: { print("• \($0)") })

        let signed = try IPAPackage.unpack(ipa: result.outputURL)
        defer { signed.cleanup(); try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(try MachOStrings.strings(url: signed.appURL.appendingPathComponent(exe)).contains(marker),
                      "the patched string should be present in the signed binary")
        try Codesigner().verify(signed.appURL)
        print("  ✅ string patched and the app verifies")
    }

    /// Full patch flow: pick a real class, build the patch dylib, inject and sign.
    func testSignsWithAGeneratedPatchDylibEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["APPSIGNER_INTEGRATION"] == "1" else {
            throw XCTSkip("set APPSIGNER_INTEGRATION=1")
        }
        let profileURL = Fixtures.profileURL
        let ipa = try XCTUnwrap(Fixtures.sourceIPAs().first)
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: profileURL))
        let identity = try XCTUnwrap(KeychainService.identities(
            try KeychainService().listCodeSigningIdentities(),
            matchingCertificateSHA1s: profile.developerCertificateSHA1s).first)

        // Pick a real class discovered by the explorer, and patch a plausible getter.
        let pkg = try IPAPackage.unpack(ipa: ipa)
        let exe = try XCTUnwrap(try InfoPlistEditor(url: pkg.appURL.appendingPathComponent("Info.plist"))
            .string(forKey: "CFBundleExecutable"))
        let className = try XCTUnwrap(MachOClassDump.classNames(url: pkg.appURL.appendingPathComponent(exe))
            .first { $0.lowercased().contains("premium") })
        pkg.cleanup()
        print("patching \(className).isEnabled -> YES")

        let buildDir = Fixtures.workspaceRoot.appendingPathComponent(".patchbuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: buildDir) }
        let dylib = try PatchDylibBuilder().build(
            [MethodPatch(className: className, selector: "isEnabled", value: .boolean(true))],
            into: buildDir)

        let out = Fixtures.workspaceRoot.appendingPathComponent("PatchTest_Signed.ipa")
        try? FileManager.default.removeItem(at: out)
        let result = try SigningPipeline().sign(
            SigningRequest(ipa: ipa, profileURL: profileURL, identitySHA1: identity.sha1,
                           dylibs: [dylib], outputURL: out),
            progress: { print("• \($0)") })

        let signed = try IPAPackage.unpack(ipa: result.outputURL)
        defer { signed.cleanup(); try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: signed.appURL.appendingPathComponent("Frameworks/AppSignerPatches.dylib").path))
        let refs = try MachOFile.read(url: signed.appURL.appendingPathComponent(exe)).dylibs
        XCTAssertTrue(refs.contains { $0.path.contains("AppSignerPatches") })
        try Codesigner().verify(signed.appURL)
        print("  ✅ patch dylib injected and the app verifies")
    }
}
