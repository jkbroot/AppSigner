import Foundation

/// A static analysis summary of a Mach-O binary's Objective-C metadata.
public struct ClassDumpReport: Equatable {
    public let classNames: [String]
    public let selectorNames: [String]
}

/// Extracts Objective-C class and selector names directly from a Mach-O binary.
///
/// Class names live in `__objc_classname` and selector names in `__objc_methname`, both
/// as plain NUL-terminated C strings. Reading them needs no pointer resolution, so this
/// works on every binary — including modern App Store apps that use chained fixups and
/// relative method lists, where following the metadata pointers would be far harder.
public enum MachOClassDump {
    /// All Objective-C class names defined or referenced by the binary.
    public static func classNames(url: URL) throws -> [String] {
        try strings(in: url, section: "__objc_classname")
    }

    /// All selector (method) names used by the binary.
    public static func selectorNames(url: URL) throws -> [String] {
        try strings(in: url, section: "__objc_methname")
    }

    public static func analyze(url: URL) throws -> ClassDumpReport {
        ClassDumpReport(classNames: try classNames(url: url),
                        selectorNames: try selectorNames(url: url))
    }

    // MARK: Internals

    /// Reads a section of NUL-separated strings, sorted and de-duplicated.
    private static func strings(in url: URL, section wanted: String) throws -> [String] {
        let data = try Data(contentsOf: url)
        guard let slice = try MachO.primarySlice(in: data) else { return [] }

        var range: (offset: Int, size: Int)?
        try MachO.forEachSection(data, slice: slice) { _, name, offset, size in
            if name == wanted { range = (slice.offset + offset, size) }
        }
        guard let range, range.size > 0, range.offset + range.size <= data.count else { return [] }

        let bytes = data.subdata(in: (data.startIndex + range.offset)..<(data.startIndex + range.offset + range.size))
        var result = Set<String>()
        var current: [UInt8] = []
        for byte in bytes {
            if byte == 0 {
                if !current.isEmpty { result.insert(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { result.insert(String(decoding: current, as: UTF8.self)) }
        return result.filter(isMeaningfulName).sorted()
    }

    /// Drops padding/noise strings, keeping identifiers (Objective-C and Swift-mangled).
    private static func isMeaningfulName(_ name: String) -> Bool {
        guard name.count >= 2, let first = name.unicodeScalars.first else { return false }
        let starters = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
        guard starters.contains(first) else { return false }
        return name.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}
