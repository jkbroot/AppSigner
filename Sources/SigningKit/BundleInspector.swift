import Foundation

/// A dylib reference resolved against the bundle it was found in.
public struct ResolvedDylib: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        case system      // ships with iOS
        case bundled     // a file inside this app bundle
        case jailbreak   // a jailbreak-only path (Substrate, rootless)
        case missing     // referenced but not present
    }
    public let path: String
    public let isWeak: Bool
    public let kind: Kind
    public let resolvedRelativePath: String?
    public var id: String { path }
}

/// One Mach-O binary discovered inside the bundle.
public struct BinaryReport: Identifiable, Equatable {
    public enum Role: String, Equatable {
        case mainExecutable, appExtension, framework, dylib, watchExecutable, other
    }
    public let id: String            // bundle-relative path
    public let role: Role
    public let architectures: [String]
    public let isEncrypted: Bool
    public let dylibs: [ResolvedDylib]
}

/// A removable (or protected) entry in the bundle.
public struct BundleItem: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        case appExtension, watchApp, appClip, framework, dylib
        case resourceBundle, localization, assetCatalog, fairplayLeftover, other
    }
    public let id: String            // bundle-relative path
    public let name: String
    public let kind: Kind
    public let sizeBytes: Int64
    public let isProtected: Bool
    public let warning: String?
    /// For nested bundles (app extensions, watch apps, app clips): their own identifier.
    public let bundleID: String?

    public init(id: String, name: String, kind: Kind, sizeBytes: Int64,
                isProtected: Bool, warning: String?, bundleID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.sizeBytes = sizeBytes
        self.isProtected = isProtected; self.warning = warning; self.bundleID = bundleID
    }
}

public struct BundleReport {
    public let appName: String
    public let bundleID: String
    public let version: String
    public let totalSize: Int64
    public let isEncrypted: Bool
    public let binaries: [BinaryReport]
    public let items: [BundleItem]
    /// bundle-relative dylib path -> binaries that reference it
    public let referrers: [String: [String]]
}

/// Scans any `.app` bundle generically: no assumptions about a particular app.
/// Everything is derived from `Info.plist` and the on-disk structure.
public struct BundleInspector {
    public init() {}

    /// Files that must never be offered for removal.
    private static let protectedNames: Set<String> = [
        "Info.plist", "embedded.mobileprovision", "_CodeSignature", "CodeResources", "PkgInfo",
    ]

    public func inspect(appURL: URL) throws -> BundleReport {
        let fm = FileManager.default
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let info = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil) as? [String: Any]) ?? [:]

        let executable = info["CFBundleExecutable"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = info["CFBundleIdentifier"] as? String ?? ""
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        // ---- Mach-O binaries anywhere in the bundle ----
        var binaries: [BinaryReport] = []
        var referrers: [String: [String]] = [:]

        if let walker = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      MachOFile.isMachO(url: url),
                      let info = try? MachOFile.read(url: url) else { continue }

                let rel = relativePath(of: url, in: appURL)
                let role = role(forBinary: rel, executable: executable)
                let resolved = info.dylibs.map { resolve($0, referrer: url, appURL: appURL) }

                for dylib in resolved where dylib.kind == .bundled {
                    if let target = dylib.resolvedRelativePath {
                        referrers[target, default: []].append(rel)
                    }
                }
                binaries.append(BinaryReport(id: rel, role: role,
                                             architectures: info.architectures,
                                             isEncrypted: info.isEncrypted,
                                             dylibs: resolved))
            }
        }

        // ---- Removable / protected entries ----
        var items: [BundleItem] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let rel = relativePath(of: url, in: appURL)
            guard !rel.isEmpty, !seen.contains(rel) else { return }
            seen.insert(rel)
            let name = url.lastPathComponent
            let isMain = (name == executable) && !rel.contains("/")
            let isProtected = isMain || Self.protectedNames.contains(name)
            items.append(BundleItem(id: rel, name: name,
                                    kind: kind(forItem: rel, name: name),
                                    sizeBytes: size(of: url),
                                    isProtected: isProtected,
                                    warning: warning(forName: name),
                                    bundleID: nestedBundleID(at: url)))
        }

        for entry in (try? fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil)) ?? [] {
            add(entry)
        }
        // One level into the container directories so each plug-in / framework is separate.
        // Apps use either `PlugIns/` or `Extensions/` for app extensions.
        for container in ["PlugIns", "Extensions", "Frameworks", "Watch", "AppClips"] {
            let dir = appURL.appendingPathComponent(container)
            for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                add(entry)
            }
            seen.insert(container)   // the container itself is represented by its children
            items.removeAll { $0.id == container }
        }

        items.sort { $0.sizeBytes > $1.sizeBytes }

        // The bundle-level flag is the main executable's: that is what decides whether
        // re-signing can produce a runnable app.
        let mainEncrypted = binaries.first { $0.role == .mainExecutable }?.isEncrypted ?? false

        return BundleReport(appName: appName, bundleID: bundleID, version: version,
                            totalSize: size(of: appURL), isEncrypted: mainEncrypted,
                            binaries: binaries, items: items, referrers: referrers)
    }

    // MARK: Classification

    private func role(forBinary rel: String, executable: String) -> BinaryReport.Role {
        if rel == executable { return .mainExecutable }
        if rel.contains(".appex/") { return .appExtension }
        if rel.contains(".framework/") { return .framework }
        if rel.hasSuffix(".dylib") { return .dylib }
        if rel.hasPrefix("Watch/") { return .watchExecutable }
        return .other
    }

    private func kind(forItem rel: String, name: String) -> BundleItem.Kind {
        if name.hasSuffix(".appex") { return .appExtension }
        if rel.hasPrefix("Watch/") { return .watchApp }
        if rel.hasPrefix("Extensions/") && name.hasSuffix(".appex") { return .appExtension }
        if rel.hasPrefix("AppClips/") { return .appClip }
        if name.hasSuffix(".framework") { return .framework }
        if name.hasSuffix(".dylib") { return .dylib }
        if name.hasSuffix(".bundle") { return .resourceBundle }
        if name.hasSuffix(".lproj") { return .localization }
        if name == "Assets.car" { return .assetCatalog }
        if name == "SC_Info" { return .fairplayLeftover }
        return .other
    }

    /// Reads `CFBundleIdentifier` from a nested bundle (.appex, .app inside Watch, …).
    private func nestedBundleID(at url: URL) -> String? {
        let ext = url.pathExtension
        guard ext == "appex" || ext == "app" else { return nil }
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    private func warning(forName name: String) -> String? {
        name == "Assets.car"
            ? "Removing the asset catalog usually breaks the app's images and icons."
            : nil
    }

    /// Classifies a raw load-command path and resolves it inside the bundle when possible.
    private func resolve(_ ref: MachOFile.DylibRef, referrer: URL, appURL: URL) -> ResolvedDylib {
        let path = ref.path
        func make(_ kind: ResolvedDylib.Kind, _ rel: String? = nil) -> ResolvedDylib {
            ResolvedDylib(path: path, isWeak: ref.isWeak, kind: kind, resolvedRelativePath: rel)
        }

        if path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/") { return make(.system) }
        if path.hasPrefix("/Library/MobileSubstrate/") || path.hasPrefix("/var/jb/")
            || path.hasPrefix("/Library/Frameworks/") { return make(.jailbreak) }

        let base = (path as NSString).lastPathComponent
        var candidates: [URL] = []
        if path.hasPrefix("@executable_path/") {
            candidates.append(appURL.appendingPathComponent(String(path.dropFirst("@executable_path/".count))))
        } else if path.hasPrefix("@loader_path/") {
            candidates.append(referrer.deletingLastPathComponent()
                .appendingPathComponent(String(path.dropFirst("@loader_path/".count))))
        } else if path.hasPrefix("@rpath/") {
            // iOS bundles put @rpath libraries in Frameworks/; also try the bundle root.
            let tail = String(path.dropFirst("@rpath/".count))
            candidates.append(appURL.appendingPathComponent("Frameworks").appendingPathComponent(tail))
            candidates.append(appURL.appendingPathComponent(tail))
        } else if !path.hasPrefix("/") {
            candidates.append(appURL.appendingPathComponent(path))
        }
        candidates.append(appURL.appendingPathComponent("Frameworks").appendingPathComponent(base))

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return make(.bundled, relativePath(of: candidate, in: appURL))
        }
        return make(.missing)
    }

    // MARK: Paths & sizes

    private func relativePath(of url: URL, in root: URL) -> String {
        let full = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in walker {
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
