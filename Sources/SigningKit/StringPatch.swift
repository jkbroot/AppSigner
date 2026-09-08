import Foundation

/// Overrides a string literal in a specific binary inside the app bundle.
///
/// Applied by rewriting the `__cstring` bytes in place before signing, so the change is
/// sealed by the signature. The replacement must not be longer than the original.
public struct StringPatch: Equatable, Codable, Identifiable {
    public var id = UUID()
    /// Bundle-relative path to the target Mach-O (the main executable, a framework,
    /// an app extension, a dylib, …).
    public let binaryPath: String
    public let original: String
    public let replacement: String

    public init(binaryPath: String, original: String, replacement: String) {
        self.binaryPath = binaryPath; self.original = original; self.replacement = replacement
    }

    /// True when the replacement fits in the original's byte slot (in-place edit).
    public var isValidLength: Bool { replacement.utf8.count <= original.utf8.count }

    public var summary: String { "\(original) → \(replacement)" }
}

/// Applies string patches to the binaries inside an unpacked `.app` bundle.
public enum StringPatcher {
    /// Rewrites each patch's target binary in place. Returns the total occurrences replaced.
    @discardableResult
    public static func apply(_ patches: [StringPatch], appURL: URL) throws -> Int {
        var total = 0
        for patch in patches {
            let binary = appURL.appendingPathComponent(patch.binaryPath)
            total += try MachOStrings.replace(patch.original, with: patch.replacement, in: binary)
        }
        return total
    }
}
