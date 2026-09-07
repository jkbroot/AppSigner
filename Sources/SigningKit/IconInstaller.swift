import Foundation
import CoreGraphics
import ImageIO

/// Replaces an app's home-screen icon by generating the standard iOS icon PNG sizes
/// from a source image and wiring them into `Info.plist` via `CFBundleIconFiles`.
///
/// This is the loose-PNG override approach: it writes opaque PNGs (iOS icons must not
/// use alpha) and removes `CFBundleIconName` so the loose files take precedence over any
/// icon compiled into `Assets.car`. It does not rewrite `Assets.car` itself.
public struct IconInstaller {
    public init() {}

    public enum IconError: Error, LocalizedError {
        case badImage, renderFailed
        public var errorDescription: String? {
            switch self {
            case .badImage: return "Could not read the source image."
            case .renderFailed: return "Failed to render the icon."
            }
        }
    }

    /// One generated icon file: full base name (with size + scale) and its pixel dimension.
    struct Spec { let fileName: String; let pixels: Int }

    static let specs: [Spec] = [
        Spec(fileName: "AppIcon20x20@2x", pixels: 40),  Spec(fileName: "AppIcon20x20@3x", pixels: 60),
        Spec(fileName: "AppIcon29x29@2x", pixels: 58),  Spec(fileName: "AppIcon29x29@3x", pixels: 87),
        Spec(fileName: "AppIcon40x40@2x", pixels: 80),  Spec(fileName: "AppIcon40x40@3x", pixels: 120),
        Spec(fileName: "AppIcon60x60@2x", pixels: 120), Spec(fileName: "AppIcon60x60@3x", pixels: 180),
    ]

    /// Base names (without size/scale) referenced by `CFBundleIconFiles`.
    static let iconBaseNames = ["AppIcon20x20", "AppIcon29x29", "AppIcon40x40", "AppIcon60x60"]

    public func install(source: URL, appURL: URL) throws {
        guard let imgSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
            throw IconError.badImage
        }
        // 1) Write the standard AppIcon set.
        for spec in Self.specs {
            let png = try renderOpaquePNG(image, pixels: spec.pixels)
            try png.write(to: appURL.appendingPathComponent("\(spec.fileName).png"))
        }
        // 2) Also override the app's existing icon references (covers icons stored in
        //    Assets.car under a custom name) by writing matching loose PNGs.
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let existing = existingIconBaseNames(infoURL: infoURL)
        for base in existing {
            let point = Self.pointSize(fromBaseName: base)
            for scale in [2, 3] {
                let png = try renderOpaquePNG(image, pixels: point * scale)
                try png.write(to: appURL.appendingPathComponent("\(base)@\(scale)x.png"))
            }
        }
        // 3) Wire Info.plist: merge our names with the existing ones, drop CFBundleIconName.
        try wireInfoPlist(at: infoURL, extraBaseNames: existing)
    }

    /// Extracts the point size encoded in a base name like "logo60x60" → 60; defaults to 60.
    static func pointSize(fromBaseName base: String) -> Int {
        guard let match = base.range(of: "[0-9]+x[0-9]+", options: .regularExpression) else { return 60 }
        let dims = base[match].split(separator: "x")
        return Int(dims.first ?? "60") ?? 60
    }

    private func existingIconBaseNames(infoURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: infoURL),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return [] }
        var names = Set<String>()
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let primary = (dict[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                names.formUnion(files)
            }
        }
        if let top = dict["CFBundleIconFiles"] as? [String] { names.formUnion(top) }
        // Ignore our own standard names so we don't double-handle them.
        names.subtract(Self.specs.map { $0.fileName })
        names.subtract(Self.iconBaseNames)
        return names.sorted()
    }

    /// Renders the image into a square, opaque PNG of the given pixel size.
    private func renderOpaquePNG(_ image: CGImage, pixels: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw IconError.renderFailed
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))  // flatten any transparency
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let rendered = ctx.makeImage() else { throw IconError.renderFailed }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw IconError.renderFailed
        }
        CGImageDestinationAddImage(dest, rendered, nil)
        guard CGImageDestinationFinalize(dest) else { throw IconError.renderFailed }
        return out as Data
    }

    private func wireInfoPlist(at url: URL, extraBaseNames: [String]) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        var dict = (try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
                    as? [String: Any]) ?? [:]

        let allFiles = Self.iconBaseNames + extraBaseNames

        // Update both iPhone and iPad icon dictionaries; drop the asset-catalog name.
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] where dict[key] != nil || key == "CFBundleIcons" {
            var icons = dict[key] as? [String: Any] ?? [:]
            var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
            primary["CFBundleIconFiles"] = allFiles
            primary.removeValue(forKey: "CFBundleIconName")   // prefer loose PNGs over Assets.car
            icons["CFBundlePrimaryIcon"] = primary
            dict[key] = icons
        }
        dict["CFBundleIconFiles"] = allFiles                  // legacy top-level key

        let outData = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
        try outData.write(to: url)
    }
}
