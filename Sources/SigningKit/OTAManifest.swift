import Foundation

/// Builds the `manifest.plist` iOS reads for an over-the-air (`itms-services`) install.
///
/// Safari opens `itms-services://?action=download-manifest&url=<https manifest>`, iOS
/// downloads this manifest, then the `.ipa` it points at, and installs it — provided the
/// app is signed with a profile that provisions the device.
public enum OTAManifest {
    /// The XML plist describing one installable app. All URLs must be HTTPS.
    public static func plist(ipaURL: String, bundleID: String, version: String, title: String,
                             displayImageURL: String? = nil, fullSizeImageURL: String? = nil) -> String {
        var assets: [[String: String]] = [["kind": "software-package", "url": ipaURL]]
        if let displayImageURL { assets.append(["kind": "display-image", "url": displayImageURL]) }
        if let fullSizeImageURL { assets.append(["kind": "full-size-image", "url": fullSizeImageURL]) }

        let item: [String: Any] = [
            "assets": assets,
            "metadata": [
                "bundle-identifier": bundleID,
                "bundle-version": version,
                "kind": "software",
                "title": title,
            ],
        ]
        let root: [String: Any] = ["items": [item]]
        let data = (try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
