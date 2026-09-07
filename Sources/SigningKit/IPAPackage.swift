import Foundation

/// Represents an unpacked IPA: a temp work directory containing `Payload/<App>.app`.
public struct IPAPackage {
    /// Extraction root (contains `Payload/`).
    public let workDir: URL
    /// `Payload/<App>.app`.
    public let appURL: URL

    public enum PackageError: Error, LocalizedError {
        case appNotFound
        public var errorDescription: String? {
            switch self { case .appNotFound: return "No .app bundle found under Payload/." }
        }
    }

    private static let fm = FileManager.default

    /// Finds the single `.app` under `<payloadParent>/Payload/`.
    public static func locateApp(payloadParent: URL) throws -> URL {
        let payload = payloadParent.appendingPathComponent("Payload")
        let entries = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw PackageError.appNotFound
        }
        return app
    }

    /// Signable components ordered inner→outer, with the `.app` bundle last.
    /// Includes loose `.dylib` files, `.framework` bundles, and `.appex` bundles.
    public static func signableComponents(appURL: URL) throws -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        if let en = fm.enumerator(at: appURL, includingPropertiesForKeys: keys) {
            for case let url as URL in en {
                let ext = url.pathExtension
                if ext == "dylib" || ext == "framework" || ext == "appex" {
                    found.append(url.standardizedFileURL)
                }
            }
        }
        // Deepest paths first so nested code signs before its container.
        found.sort { $0.pathComponents.count > $1.pathComponents.count }
        found.append(appURL.standardizedFileURL)
        return found
    }

    /// Unzips an IPA into a fresh temp work directory and locates the app.
    public static func unpack(ipa: URL, runner: ProcessRunner = .init()) throws -> IPAPackage {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppSigner-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try runner.runThrowing("/usr/bin/unzip", ["-q", "-o", ipa.path, "-d", work.path])
        let app = try locateApp(payloadParent: work)
        return IPAPackage(workDir: work, appURL: app)
    }

    /// Zips `Payload/` back into `outputIPA` (overwriting), storing relative paths.
    public func repack(to outputIPA: URL, runner: ProcessRunner = .init()) throws {
        try? Self.fm.removeItem(at: outputIPA)
        try runner.runThrowing("/usr/bin/zip",
                               ["-r", "-q", "-y", outputIPA.path, "Payload"],
                               cwd: workDir)
    }

    public func cleanup() {
        try? Self.fm.removeItem(at: workDir)
    }
}

extension IPAPackage {
    public struct AppInfo {
        public let bundleID: String
        public let displayName: String
        public let shortVersion: String
        public let bundleVersion: String
        public let appBundleName: String
    }
    /// Reads app metadata by extracting only `Payload/<App>.app/Info.plist` — avoids a full unpack.
    public static func readAppInfo(ipa: URL, runner: ProcessRunner = .init()) throws -> AppInfo {
        let listing = try runner.runThrowing("/usr/bin/unzip", ["-Z1", ipa.path]).stdout
        guard let entry = listing.split(separator: "\n").map(String.init).first(where: {
            $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist")
                && $0.filter({ $0 == "/" }).count == 2
        }) else {
            throw PackageError.appNotFound
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("info-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try runner.runThrowing("/usr/bin/unzip", ["-q", "-o", ipa.path, entry, "-d", tmp.path])

        let plistURL = tmp.appendingPathComponent(entry)
        let data = try Data(contentsOf: plistURL)
        let dict = (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]

        let appBundleName = String(entry.dropFirst("Payload/".count)).replacingOccurrences(of: "/Info.plist", with: "")
        return AppInfo(
            bundleID: dict["CFBundleIdentifier"] as? String ?? "",
            displayName: (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) ?? "",
            shortVersion: dict["CFBundleShortVersionString"] as? String ?? "",
            bundleVersion: dict["CFBundleVersion"] as? String ?? "",
            appBundleName: appBundleName
        )
    }
}
