import Foundation

/// Targets one dylib load command inside one Mach-O of the bundle.
public struct DylibEdit: Equatable {
    /// Bundle-relative path of the Mach-O to edit (e.g. "Demo", "PlugIns/X.appex/X").
    public let binaryPath: String
    /// The load-command path as it appears in the binary (e.g. "@rpath/Tweak.dylib").
    public let dylibPath: String
    public init(binaryPath: String, dylibPath: String) {
        self.binaryPath = binaryPath; self.dylibPath = dylibPath
    }
}

/// The set of changes to apply to an unpacked `.app` before signing.
public struct BundleEdits: Equatable {
    /// Bundle-relative files or directories to delete.
    public var removedPaths: [String] = []
    /// Dylib load commands to strip.
    public var removedDylibs: [DylibEdit] = []
    /// References to convert to `LC_LOAD_WEAK_DYLIB`.
    public var weakenedDylibs: [DylibEdit] = []

    public init() {}
    public var isEmpty: Bool {
        removedPaths.isEmpty && removedDylibs.isEmpty && weakenedDylibs.isEmpty
    }
}

/// Applies `BundleEdits` to an unpacked app bundle.
///
/// Works on any app: the only assumptions are the bundle's own `Info.plist` and a
/// fixed set of files that must never be deleted.
public struct BundleEditor {
    public enum EditError: Error, LocalizedError, Equatable {
        case protectedPath(String)
        case invalidPath(String)
        case missingBinary(String)

        public var errorDescription: String? {
            switch self {
            case .protectedPath(let p): return "'\(p)' is required by the app and cannot be removed."
            case .invalidPath(let p): return "'\(p)' is not a valid path inside the app bundle."
            case .missingBinary(let p): return "Binary '\(p)' was not found in the app bundle."
            }
        }
    }

    /// Never deletable, whatever the caller asks for.
    private static let protectedNames: Set<String> = [
        "Info.plist", "embedded.mobileprovision", "_CodeSignature", "CodeResources", "PkgInfo",
    ]

    public init() {}

    public func apply(_ edits: BundleEdits, to appURL: URL,
                      progress: ((String) -> Void)? = nil) throws {
        guard !edits.isEmpty else { return }
        let executable = mainExecutableName(appURL: appURL)

        // Validate everything before touching the bundle, so a bad request changes nothing.
        for path in edits.removedPaths {
            let url = try resolve(path, in: appURL)
            let name = url.lastPathComponent
            if Self.protectedNames.contains(name) || (name == executable && !path.contains("/")) {
                throw EditError.protectedPath(path)
            }
        }

        // 1) Binary edits first — a later file deletion must not remove a binary we edit.
        for edit in edits.weakenedDylibs {
            let binary = try resolveBinary(edit.binaryPath, in: appURL)
            progress?("Weakening \(edit.dylibPath) in \(edit.binaryPath)")
            try MachOInjector.setWeak(true, forDylib: edit.dylibPath, in: binary)
        }
        for edit in edits.removedDylibs {
            let binary = try resolveBinary(edit.binaryPath, in: appURL)
            progress?("Removing \(edit.dylibPath) from \(edit.binaryPath)")
            try MachOInjector.removeDylib(path: edit.dylibPath, from: binary)
        }

        // 2) File and directory removals.
        for path in edits.removedPaths {
            let url = try resolve(path, in: appURL)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            progress?("Removing \(path)")
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Copies tweak resource bundles (from a `.deb`, say) into the app root, replacing
    /// any existing bundle of the same name. Done before signing so they are sealed.
    public func installResourceBundles(_ bundles: [URL], into appURL: URL,
                                       progress: ((String) -> Void)? = nil) throws {
        for bundle in bundles {
            let destination = appURL.appendingPathComponent(bundle.lastPathComponent)
            progress?("Adding \(bundle.lastPathComponent)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: bundle, to: destination)
        }
    }

    // MARK: Helpers

    private func mainExecutableName(appURL: URL) -> String {
        let info = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")),
            format: nil) as? [String: Any]) ?? [:]
        return info["CFBundleExecutable"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    /// Resolves a bundle-relative path, rejecting anything that escapes the bundle.
    private func resolve(_ path: String, in appURL: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else { throw EditError.invalidPath(path) }
        let url = appURL.appendingPathComponent(path).standardizedFileURL
        let root = appURL.standardizedFileURL.path
        guard url.path == root || url.path.hasPrefix(root + "/") else {
            throw EditError.invalidPath(path)
        }
        return url
    }

    private func resolveBinary(_ path: String, in appURL: URL) throws -> URL {
        let url = try resolve(path, in: appURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EditError.missingBinary(path)
        }
        return url
    }
}
