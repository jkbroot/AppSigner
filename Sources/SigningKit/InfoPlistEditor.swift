import Foundation

/// A typed value for the raw (advanced) key editor.
public enum PlistValue: Equatable, Codable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case stringArray([String])

    var plistObject: Any {
        switch self {
        case .string(let v): return v
        case .bool(let v): return v
        case .integer(let v): return v
        case .stringArray(let v): return v
        }
    }

    // Tagged encoding so presets round-trip every case exactly.
    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):      try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
        case .bool(let v):        try c.encode("bool", forKey: .type);   try c.encode(v, forKey: .value)
        case .integer(let v):     try c.encode("integer", forKey: .type); try c.encode(v, forKey: .value)
        case .stringArray(let v): try c.encode("list", forKey: .type);   try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "string":  self = .string(try c.decode(String.self, forKey: .value))
        case "bool":    self = .bool(try c.decode(Bool.self, forKey: .value))
        case "integer": self = .integer(try c.decode(Int.self, forKey: .value))
        case "list":    self = .stringArray(try c.decode([String].self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "unknown value type '\(other)'")
        }
    }
}

/// Edits to apply to an `Info.plist`. `nil` fields are left untouched.
public struct InfoPlistEdits {
    // Basics
    public var bundleIdentifier: String?
    public var shortVersion: String?
    public var bundleVersion: String?
    public var displayName: String?

    // Advanced, curated
    /// `MinimumOSVersion` — lets the app install on older systems (it may still use newer APIs).
    public var minimumOSVersion: String?
    /// `UIDeviceFamily`: 1 = iPhone, 2 = iPad.
    public var deviceFamilies: [Int]?
    /// `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`.
    public var fileSharingEnabled: Bool?
    /// `NSAppTransportSecurity.NSAllowsArbitraryLoads`, merged into any existing ATS settings.
    public var allowArbitraryLoads: Bool?
    /// Delete `UIRequiredDeviceCapabilities` to widen device compatibility.
    public var removeRequiredCapabilities = false
    /// Prefix every `CFBundleURLSchemes` entry so two copies of an app do not clash.
    public var urlSchemePrefix: String?

    // Advanced, raw
    public var removedKeys: [String] = []
    public var customValues: [String: PlistValue] = [:]

    public init(bundleIdentifier: String? = nil, shortVersion: String? = nil,
                bundleVersion: String? = nil, displayName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.displayName = displayName
    }

    public var isEmpty: Bool {
        bundleIdentifier == nil && shortVersion == nil && bundleVersion == nil && displayName == nil
            && minimumOSVersion == nil && deviceFamilies == nil && fileSharingEnabled == nil
            && allowArbitraryLoads == nil && !removeRequiredCapabilities && urlSchemePrefix == nil
            && removedKeys.isEmpty && customValues.isEmpty
    }
}

/// Reads and edits an `Info.plist`, preserving its on-disk format (binary/XML).
public struct InfoPlistEditor {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// Keys whose loss would break the bundle outright.
    public static let protectedKeys: Set<String> = ["CFBundleExecutable"]

    public enum EditorError: Error, LocalizedError, Equatable {
        case notADictionary
        case protectedKey(String)
        public var errorDescription: String? {
            switch self {
            case .notADictionary: return "Info.plist is not a dictionary."
            case .protectedKey(let k): return "'\(k)' is required by the app and cannot be changed."
            }
        }
    }

    public func string(forKey key: String) throws -> String? {
        try load().dict[key] as? String
    }

    /// The whole property list, for showing current values in an editor.
    public func dictionary() throws -> [String: Any] {
        try load().dict
    }

    public func apply(_ edits: InfoPlistEdits) throws {
        // Validate before writing anything.
        for key in edits.removedKeys where Self.protectedKeys.contains(key) {
            throw EditorError.protectedKey(key)
        }
        for key in edits.customValues.keys where Self.protectedKeys.contains(key) {
            throw EditorError.protectedKey(key)
        }

        var (dict, format) = try load()

        // Basics
        if let v = edits.bundleIdentifier { dict["CFBundleIdentifier"] = v }
        if let v = edits.shortVersion     { dict["CFBundleShortVersionString"] = v }
        if let v = edits.bundleVersion    { dict["CFBundleVersion"] = v }
        if let v = edits.displayName {
            dict["CFBundleDisplayName"] = v
            dict["CFBundleName"] = v
        }

        // Curated advanced options
        if let v = edits.minimumOSVersion { dict["MinimumOSVersion"] = v }
        if let v = edits.deviceFamilies   { dict["UIDeviceFamily"] = v }
        if let v = edits.fileSharingEnabled {
            dict["UIFileSharingEnabled"] = v
            dict["LSSupportsOpeningDocumentsInPlace"] = v
        }
        if let v = edits.allowArbitraryLoads {
            var ats = dict["NSAppTransportSecurity"] as? [String: Any] ?? [:]
            ats["NSAllowsArbitraryLoads"] = v
            dict["NSAppTransportSecurity"] = ats
        }
        if edits.removeRequiredCapabilities {
            dict.removeValue(forKey: "UIRequiredDeviceCapabilities")
        }
        if let prefix = edits.urlSchemePrefix, !prefix.isEmpty,
           let types = dict["CFBundleURLTypes"] as? [[String: Any]] {
            dict["CFBundleURLTypes"] = types.map { entry -> [String: Any] in
                var entry = entry
                if let schemes = entry["CFBundleURLSchemes"] as? [String] {
                    entry["CFBundleURLSchemes"] = schemes.map { prefix + $0 }
                }
                return entry
            }
        }

        // Raw edits
        for key in edits.removedKeys { dict.removeValue(forKey: key) }
        for (key, value) in edits.customValues { dict[key] = value.plistObject }

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
        try data.write(to: url)
    }

    private func load() throws -> (dict: [String: Any], format: PropertyListSerialization.PropertyListFormat) {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let dict = obj as? [String: Any] else { throw EditorError.notADictionary }
        return (dict, format)
    }
}
