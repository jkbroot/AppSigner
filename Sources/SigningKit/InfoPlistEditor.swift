import Foundation

/// Edits to apply to an `Info.plist`. `nil` fields are left untouched.
public struct InfoPlistEdits {
    public var bundleIdentifier: String?
    public var shortVersion: String?
    public var bundleVersion: String?
    public var displayName: String?

    public init(bundleIdentifier: String? = nil, shortVersion: String? = nil,
                bundleVersion: String? = nil, displayName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.displayName = displayName
    }

    public var isEmpty: Bool {
        bundleIdentifier == nil && shortVersion == nil && bundleVersion == nil && displayName == nil
    }
}

/// Reads and edits an `Info.plist`, preserving its on-disk format (binary/XML).
public struct InfoPlistEditor {
    public let url: URL
    public init(url: URL) { self.url = url }

    public enum EditorError: Error, LocalizedError {
        case notADictionary
        public var errorDescription: String? {
            switch self {
            case .notADictionary: return "Info.plist is not a dictionary."
            }
        }
    }

    public func string(forKey key: String) throws -> String? {
        try load().dict[key] as? String
    }

    public func apply(_ edits: InfoPlistEdits) throws {
        var (dict, format) = try load()
        if let v = edits.bundleIdentifier { dict["CFBundleIdentifier"] = v }
        if let v = edits.shortVersion     { dict["CFBundleShortVersionString"] = v }
        if let v = edits.bundleVersion    { dict["CFBundleVersion"] = v }
        if let v = edits.displayName {
            dict["CFBundleDisplayName"] = v
            dict["CFBundleName"] = v
        }
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
