import Foundation

/// Reads a Cydia/Sileo tweak package (`.deb`).
///
/// A `.deb` is an `ar` container holding `control.tar.*` (metadata) and `data.tar.*`
/// (the files as they would be installed on a jailbroken device). macOS' `tar` (bsdtar)
/// reads the `ar` container directly and auto-detects gzip / xz / bzip2 / zstd, so no
/// extra tooling is needed.
///
/// Both the classic layout (`/Library/MobileSubstrate/DynamicLibraries`) and the rootless
/// one (`/var/jb/Library/...`) are handled by searching the payload generically.
public enum DebPackage {
    public struct Info: Equatable {
        public let identifier: String
        public let name: String
        public let version: String
        public let author: String?
        public let dependencies: [String]
    }

    public struct Contents {
        public let info: Info
        /// Tweak libraries found in the payload.
        public let dylibs: [URL]
        /// Resource bundles the tweak loads at runtime.
        public let bundles: [URL]
        /// Frameworks shipped by the package (e.g. a CydiaSubstrate shim).
        public let frameworks: [URL]
        /// Bundle ids the tweak declares it targets (from its filter plist).
        public let targetBundleIDs: [String]
        /// The package depends on Substrate / ElleKit.
        public let requiresSubstrate: Bool
        /// Extraction directory — the caller owns and cleans it up.
        public let root: URL
    }

    public enum DebError: Error, LocalizedError {
        case notADeb, noPayload
        public var errorDescription: String? {
            switch self {
            case .notADeb: return "This file is not a valid .deb package."
            case .noPayload: return "The package has no data payload."
            }
        }
    }

    private static let substrateDependencies = ["mobilesubstrate", "ellekit", "substrate", "substitute"]

    public static func extract(deb: URL, to dir: URL,
                               runner: ProcessRunner = .init()) throws -> Contents {
        let fm = FileManager.default
        let members = dir.appendingPathComponent("members")
        let payload = dir.appendingPathComponent("payload")
        let controlDir = dir.appendingPathComponent("control")
        for d in [members, payload, controlDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        // 1) Unpack the ar container.
        guard (try? runner.runThrowing("/usr/bin/tar", ["-xf", deb.path, "-C", members.path])) != nil else {
            throw DebError.notADeb
        }
        let entries = (try? fm.contentsOfDirectory(at: members, includingPropertiesForKeys: nil)) ?? []
        guard entries.contains(where: { $0.lastPathComponent == "debian-binary" }) else {
            throw DebError.notADeb
        }

        // 2) Unpack the payload and the metadata (compression is auto-detected).
        guard let dataTar = entries.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) else {
            throw DebError.noPayload
        }
        try runner.runThrowing("/usr/bin/tar", ["-xf", dataTar.path, "-C", payload.path])
        if let controlTar = entries.first(where: { $0.lastPathComponent.hasPrefix("control.tar") }) {
            try? runner.runThrowing("/usr/bin/tar", ["-xf", controlTar.path, "-C", controlDir.path])
        }

        // 3) Metadata.
        let controlText = (try? String(contentsOf: controlDir.appendingPathComponent("control"),
                                       encoding: .utf8)) ?? ""
        let fields = parseControl(controlText)
        let dependencies = (fields["Depends"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let identifier = fields["Package"] ?? ""
        let info = Info(identifier: identifier,
                        name: fields["Name"] ?? identifier,
                        version: fields["Version"] ?? "",
                        author: fields["Author"] ?? fields["Maintainer"],
                        dependencies: dependencies)

        // 4) Payload contents — searched generically so rootful and rootless both work.
        var dylibs: [URL] = [], bundles: [URL] = [], frameworks: [URL] = []
        if let walker = fm.enumerator(at: payload, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir, url.pathExtension == "framework" {
                    frameworks.append(url)
                    walker.skipDescendants()          // its binary is not a loose dylib
                    continue
                }
                if isDir, url.pathExtension == "bundle" {
                    bundles.append(url)
                    walker.skipDescendants()
                    continue
                }
                if !isDir, url.pathExtension == "dylib" { dylibs.append(url) }
            }
        }
        dylibs.sort { $0.lastPathComponent < $1.lastPathComponent }
        bundles.sort { $0.lastPathComponent < $1.lastPathComponent }
        frameworks.sort { $0.lastPathComponent < $1.lastPathComponent }

        // 5) Target bundle ids from each tweak's filter plist.
        var targets: [String] = []
        for dylib in dylibs {
            let plist = dylib.deletingPathExtension().appendingPathExtension("plist")
            guard let data = try? Data(contentsOf: plist),
                  let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let filter = root["Filter"] as? [String: Any],
                  let bundleIDs = filter["Bundles"] as? [String] else { continue }
            targets.append(contentsOf: bundleIDs)
        }

        let needsSubstrate = dependencies.contains { dependency in
            let name = dependency.lowercased()
            return Self.substrateDependencies.contains { name.contains($0) }
        }

        return Contents(info: info, dylibs: dylibs, bundles: bundles, frameworks: frameworks,
                        targetBundleIDs: Array(Set(targets)).sorted(),
                        requiresSubstrate: needsSubstrate, root: dir)
    }

    /// Parses the "Key: value" control file, joining folded continuation lines.
    static func parseControl(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        var lastKey: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = lastKey {
                    fields[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
            lastKey = key
        }
        return fields
    }
}
