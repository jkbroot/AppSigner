import XCTest
import ImageIO
import CoreGraphics
@testable import SigningKit

final class IconInstallerTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Creates a solid-color square PNG for use as a source image.
    private func makeSourcePNG(_ pixels: Int, in dir: URL) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let image = ctx.makeImage()!
        let url = dir.appendingPathComponent("source.png")
        let dest = CGImageDestinationCreateWithData(NSMutableData() as CFMutableData, "public.png" as CFString, 1, nil)!
        // write to file instead
        let fileDest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(fileDest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(fileDest))
        _ = dest
        return url
    }

    private func pixelSize(of url: URL) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private func makeApp(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.demo",
                                   "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    func testGeneratesHomeScreenIconsAtCorrectSizes() throws {
        let dir = try tempDir()
        let source = try makeSourcePNG(256, in: dir)
        let app = try makeApp(in: dir)
        try IconInstaller().install(source: source, appURL: app)

        XCTAssertEqual(pixelSize(of: app.appendingPathComponent("AppIcon60x60@2x.png"))?.w, 120)
        XCTAssertEqual(pixelSize(of: app.appendingPathComponent("AppIcon60x60@3x.png"))?.w, 180)
        XCTAssertEqual(pixelSize(of: app.appendingPathComponent("AppIcon60x60@3x.png"))?.h, 180)
    }

    func testWiresInfoPlistIconKeysAndRemovesIconName() throws {
        let dir = try tempDir()
        let source = try makeSourcePNG(200, in: dir)
        let app = try makeApp(in: dir)
        try IconInstaller().install(source: source, appURL: app)

        let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let primary = (dict?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        XCTAssertEqual(files?.contains("AppIcon60x60"), true)
        XCTAssertNil(primary?["CFBundleIconName"], "asset-catalog icon name should be removed so loose PNGs win")
    }
}

extension IconInstallerTests {
    /// Apps whose icon lives in Assets.car reference it by a custom base name in
    /// CFBundleIconFiles. The installer must also write matching loose PNGs for that
    /// existing name so the override wins regardless of which reference iOS follows.
    func testOverridesExistingCustomIconBaseNames() throws {
        let dir = try tempDir()
        let source = try makeSourcePNG(256, in: dir)
        let app = dir.appendingPathComponent("Custom.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.custom",
            "CFBundleIcons": ["CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["logo_brand60x60"],
                "CFBundleIconName": "logo_brand",
            ]],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))

        try IconInstaller().install(source: source, appURL: app)

        // Loose PNG for the app's ORIGINAL icon name is written at the right size (60pt).
        XCTAssertEqual(pixelSize(of: app.appendingPathComponent("logo_brand60x60@2x.png"))?.w, 120)
        XCTAssertEqual(pixelSize(of: app.appendingPathComponent("logo_brand60x60@3x.png"))?.w, 180)

        let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let primary = (dict?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        XCTAssertTrue(files.contains("logo_brand60x60"), "keeps + overrides the original icon reference")
        XCTAssertTrue(files.contains("AppIcon60x60"), "also provides standard AppIcon files")
        XCTAssertNil(primary?["CFBundleIconName"])
    }
}
