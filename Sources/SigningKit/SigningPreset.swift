import Foundation

/// A saved signing configuration.
///
/// Deliberately app-agnostic: it never stores the bundle id, display name or version,
/// because those are specific to one app and reusing them across a batch would produce
/// colliding bundle identifiers.
public struct SigningPreset: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String

    // Signing inputs
    public var profilePath: String?
    public var identitySHA1: String?
    public var dylibPaths: [String] = []
    public var iconPath: String?
    public var injectWeak = true

    // Advanced Info.plist options
    public var minimumOSVersion: String?
    public var deviceFamilies: [Int]?
    public var fileSharingEnabled: Bool?
    public var allowArbitraryLoads: Bool?
    public var removeRequiredCapabilities = false
    public var urlSchemePrefix: String?
    public var removedPlistKeys: [String] = []
    public var customPlistValues: [String: PlistValue] = [:]

    public init(name: String) { self.name = name }
}

/// Stores presets as JSON on disk.
public struct PresetStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("presets.json") }

    /// Defaults to `~/Library/Application Support/AppSigner`.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("AppSigner", isDirectory: true)
        }
    }

    public func load() -> [SigningPreset] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SigningPreset].self, from: data)) ?? []
    }

    public func save(_ presets: [SigningPreset]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL)
    }

    /// Adds a preset, replacing any existing one with the same name.
    @discardableResult
    public func add(_ preset: SigningPreset) throws -> [SigningPreset] {
        var presets = load().filter { $0.name != preset.name }
        presets.append(preset)
        try save(presets)
        return presets
    }

    @discardableResult
    public func delete(id: UUID) throws -> [SigningPreset] {
        let presets = load().filter { $0.id != id }
        try save(presets)
        return presets
    }
}
