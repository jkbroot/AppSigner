import Foundation

/// Reads and edits the human-readable string literals in a Mach-O binary.
///
/// String literals live in `__TEXT,__cstring` as NUL-terminated C strings — the same
/// simple layout the class-dump reader uses, so no pointer resolution is needed and it
/// works on every binary, including chained-fixups App Store apps.
public enum MachOStrings {
    static let section = "__cstring"

    public enum StringEditError: Error, Equatable {
        /// The replacement is longer (in UTF-8 bytes) than the original it overwrites.
        case tooLong(original: Int, replacement: Int)
        /// The original string was not found in the binary.
        case notFound(String)
    }

    /// Printable string literals from `__TEXT,__cstring`, de-duplicated and sorted.
    public static func strings(url: URL, minLength: Int = 2) throws -> [String] {
        let data = try Data(contentsOf: url)
        guard let slice = try MachO.primarySlice(in: data) else { return [] }
        guard let range = try sectionRange(data, slice: slice) else { return [] }

        var result = Set<String>()
        forEachEntry(in: data, range: range) { bytes, _ in
            let s = String(decoding: bytes, as: UTF8.self)
            if isPrintable(s, minLength: minLength) { result.insert(s) }
        }
        return result.sorted()
    }

    /// Replaces every whole `__cstring` entry equal to `original` with `replacement`,
    /// in place, across every slice. The replacement must not be longer (in UTF-8 bytes)
    /// than the original, so file size and section offsets never change. Returns the
    /// number of occurrences replaced.
    @discardableResult
    public static func replace(_ original: String, with replacement: String, in url: URL) throws -> Int {
        let originalBytes = Array(original.utf8)
        let replacementBytes = Array(replacement.utf8)
        guard replacementBytes.count <= originalBytes.count else {
            throw StringEditError.tooLong(original: originalBytes.count, replacement: replacementBytes.count)
        }

        var data = try Data(contentsOf: url)
        // Pad the replacement with NULs to the original's length: the first NUL terminates
        // the C string, the rest overwrite the old tail. Same length ⇒ same file layout.
        var newRegion = replacementBytes
        while newRegion.count < originalBytes.count { newRegion.append(0) }

        var count = 0
        for slice in try MachO.slices(in: data) {
            guard let range = try sectionRange(data, slice: slice) else { continue }
            for offset in entryOffsets(in: data, range: range, matching: originalBytes) {
                let start = data.startIndex + offset
                data.replaceSubrange(start..<(start + originalBytes.count), with: newRegion)
                count += 1
            }
        }
        guard count > 0 else { throw StringEditError.notFound(original) }
        try data.write(to: url)
        return count
    }

    // MARK: Internals

    /// Offsets (relative to the data start) of every whole entry equal to `target`.
    private static func entryOffsets(in data: Data, range: (offset: Int, size: Int),
                                     matching target: [UInt8]) -> [Int] {
        guard !target.isEmpty else { return [] }
        var offsets: [Int] = []
        forEachEntry(in: data, range: range) { bytes, offset in
            if bytes == target { offsets.append(offset) }
        }
        return offsets
    }

    /// The absolute file range of `__cstring` in a slice, or nil when absent.
    private static func sectionRange(_ data: Data, slice: MachO.Slice) throws -> (offset: Int, size: Int)? {
        var found: (offset: Int, size: Int)?
        try MachO.forEachSection(data, slice: slice) { _, name, offset, size in
            if name == section { found = (slice.offset + offset, size) }
        }
        guard let found, found.size > 0, found.offset + found.size <= data.count else { return nil }
        return found
    }

    /// Calls `body` once per NUL-terminated entry: (bytes, offset-from-data-start).
    private static func forEachEntry(in data: Data, range: (offset: Int, size: Int),
                                     _ body: ([UInt8], Int) -> Void) {
        let start = data.startIndex + range.offset
        let end = start + range.size
        var current: [UInt8] = []
        var entryStart = start
        for i in start..<end {
            let byte = data[i]
            if byte == 0 {
                if !current.isEmpty { body(current, entryStart - data.startIndex) }
                current.removeAll(keepingCapacity: true)
                entryStart = i + 1
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { body(current, entryStart - data.startIndex) }
    }

    /// Keeps readable strings: no control characters and at least one letter or digit.
    private static func isPrintable(_ s: String, minLength: Int) -> Bool {
        guard s.count >= minLength else { return false }
        var hasAlphanumeric = false
        for scalar in s.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if CharacterSet.alphanumerics.contains(scalar) { hasAlphanumeric = true }
        }
        return hasAlphanumeric
    }
}
