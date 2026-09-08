import Foundation

/// Shared Mach-O constants and byte primitives used by the reader and the injector.
enum MachO {
    static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    static let FAT_MAGIC_64: UInt32 = 0xCAFEBABF
    static let MH_MAGIC_64: UInt32 = 0xFEEDFACF   // 64-bit little-endian
    static let MH_MAGIC_32: UInt32 = 0xFEEDFACE   // 32-bit little-endian

    static let LC_REQ_DYLD: UInt32 = 0x8000_0000
    static let LC_LOAD_DYLIB: UInt32 = 0x0C
    static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x18 | LC_REQ_DYLD
    static let LC_REEXPORT_DYLIB: UInt32 = 0x1F | LC_REQ_DYLD
    static let LC_LOAD_UPWARD_DYLIB: UInt32 = 0x23 | LC_REQ_DYLD
    static let LC_ENCRYPTION_INFO: UInt32 = 0x21
    static let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C

    /// Load commands that reference another dylib by path.
    static let dylibCommands: Set<UInt32> = [
        LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB,
    ]

    enum ByteError: Error { case outOfBounds }

    static func u32(_ d: Data, _ off: Int, bigEndian: Bool = false) throws -> UInt32 {
        let s = d.startIndex + off
        guard off >= 0, s + 4 <= d.endIndex else { throw ByteError.outOfBounds }
        let b = [UInt8](d[s..<s + 4])
        let v = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return bigEndian ? v.byteSwapped : v
    }

    static func u64(_ d: Data, _ off: Int, bigEndian: Bool = false) throws -> UInt64 {
        let s = d.startIndex + off
        guard off >= 0, s + 8 <= d.endIndex else { throw ByteError.outOfBounds }
        let b = [UInt8](d[s..<s + 8])
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }
        return bigEndian ? v.byteSwapped : v
    }

    static func writeU32(_ d: inout Data, _ off: Int, _ value: UInt32) throws {
        let s = d.startIndex + off
        guard off >= 0, s + 4 <= d.endIndex else { throw ByteError.outOfBounds }
        let bytes: [UInt8] = [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff),
        ]
        d.replaceSubrange(s..<s + 4, with: bytes)
    }

    /// A null-terminated string inside a load command.
    static func cString(_ d: Data, at off: Int, limit: Int) -> String {
        let start = d.startIndex + off
        guard start < d.endIndex else { return "" }
        let end = min(start + limit, d.endIndex)
        var bytes: [UInt8] = []
        for i in start..<end {
            let byte = d[i]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func archName(cputype: UInt32, cpusubtype: UInt32) -> String {
        switch cputype {
        case 0x0100_000C: return (cpusubtype & 0xFF) == 2 ? "arm64e" : "arm64"
        case 0x0000_000C: return "armv7"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return "unknown(\(cputype))"
        }
    }

    /// One architecture slice inside a file (offset 0 for a thin binary).
    struct Slice {
        let offset: Int
        let magic: UInt32
        var is64: Bool { magic == MH_MAGIC_64 }
        var headerSize: Int { is64 ? 32 : 28 }
    }

    /// Enumerates the slices of a thin or fat Mach-O.
    static func slices(in data: Data) throws -> [Slice] {
        guard data.count >= 8 else { return [] }
        let magicBE = try u32(data, 0, bigEndian: true)
        if magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 {
            let is64 = magicBE == FAT_MAGIC_64
            let count = try u32(data, 4, bigEndian: true)
            var result: [Slice] = []
            var archOff = 8
            for _ in 0..<count {
                let offset: Int = is64
                    ? Int(try u64(data, archOff + 8, bigEndian: true))
                    : Int(try u32(data, archOff + 8, bigEndian: true))
                archOff += is64 ? 32 : 20
                guard offset >= 0, offset + 4 <= data.count else { continue }
                let magic = try u32(data, offset)
                result.append(Slice(offset: offset, magic: magic))
            }
            return result
        }
        let magic = try u32(data, 0)
        guard magic == MH_MAGIC_64 || magic == MH_MAGIC_32 else { return [] }
        return [Slice(offset: 0, magic: magic)]
    }

    /// Calls `body` for each section in a slice: (segment, section, fileOffset, size).
    static func forEachSection(_ data: Data, slice: Slice,
                               _ body: (String, String, Int, Int) throws -> Void) throws {
        try forEachCommand(data, slice: slice) { cmd, _, at in
            guard cmd == 0x19 else { return }          // LC_SEGMENT_64
            let nsects = Int(try u32(data, at + 64))
            var sp = at + 72
            for _ in 0..<nsects {
                let sectname = cString(data, at: sp, limit: 16)
                let segname = cString(data, at: sp + 16, limit: 16)
                let offset = Int(try u32(data, sp + 48))
                let size = Int(try u64(data, sp + 40))
                try body(segname, sectname, offset, size)
                sp += 80
            }
        }
    }

    /// The 64-bit slice best suited for reading metadata (prefers arm64).
    static func primarySlice(in data: Data) throws -> Slice? {
        let slices = try slices(in: data).filter { $0.is64 }
        return slices.first { s in
            (try? u32(data, s.offset + 4)) == 0x0100_000C     // CPU_TYPE_ARM64
        } ?? slices.first
    }

    /// Calls `body` for each load command in a slice: (command, cmdsize, absolute offset).
    static func forEachCommand(_ data: Data, slice: Slice,
                               _ body: (UInt32, Int, Int) throws -> Void) throws {
        let ncmds = try u32(data, slice.offset + 16)
        var p = slice.offset + slice.headerSize
        for _ in 0..<ncmds {
            guard p + 8 <= data.count else { return }
            let cmd = try u32(data, p)
            let size = Int(try u32(data, p + 4))
            guard size > 0, p + size <= data.count else { return }
            try body(cmd, size, p)
            p += size
        }
    }
}

/// Read-only information about any Mach-O file.
public struct MachOInfo {
    public let architectures: [String]
    public let isEncrypted: Bool
    public let dylibs: [MachOFile.DylibRef]
}

/// Generic Mach-O reader: works for thin and fat files, 32-bit and 64-bit slices.
public enum MachOFile {
    public struct DylibRef: Equatable {
        public let path: String
        public let isWeak: Bool
        public init(path: String, isWeak: Bool) { self.path = path; self.isWeak = isWeak }
    }

    /// Jailbreak-only prefixes whose libraries can be re-pointed into the app bundle.
    private static let jailbreakPrefixes = [
        "/var/jb/Library/", "/var/jb/usr/lib/", "/Library/MobileSubstrate/",
        "/Library/Frameworks/", "/Library/",
    ]

    /// Maps a jailbreak install path to the `@rpath` form used inside a signed app.
    /// Returns nil for system paths and for paths that are already relative.
    ///
    /// `/Library/Frameworks/X.framework/X` -> `@rpath/X.framework/X`
    /// `/Library/MobileSubstrate/DynamicLibraries/T.dylib` -> `@rpath/T.dylib`
    public static func suggestedRPath(for path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }                       // already relative
        guard path.hasPrefix("/var/jb/") || path.hasPrefix("/Library/") else { return nil }
        guard jailbreakPrefixes.contains(where: { path.hasPrefix($0) }) else { return nil }

        // Keep the framework wrapper when there is one, otherwise just the file name.
        let components = path.split(separator: "/").map(String.init)
        if let index = components.firstIndex(where: { $0.hasSuffix(".framework") }) {
            return "@rpath/" + components[index...].joined(separator: "/")
        }
        return "@rpath/" + ((path as NSString).lastPathComponent)
    }

    public static func isMachO(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count >= 4 else { return false }
        guard let beMagic = try? MachO.u32(head, 0, bigEndian: true),
              let leMagic = try? MachO.u32(head, 0) else { return false }
        return beMagic == MachO.FAT_MAGIC || beMagic == MachO.FAT_MAGIC_64
            || leMagic == MachO.MH_MAGIC_64 || leMagic == MachO.MH_MAGIC_32
    }

    public static func read(url: URL) throws -> MachOInfo {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    static func read(data: Data) throws -> MachOInfo {
        var architectures: [String] = []
        var encrypted = false
        var dylibs: [DylibRef] = []
        var seen = Set<String>()

        for slice in try MachO.slices(in: data) {
            let cputype = try MachO.u32(data, slice.offset + 4)
            let cpusubtype = try MachO.u32(data, slice.offset + 8)
            architectures.append(MachO.archName(cputype: cputype, cpusubtype: cpusubtype))

            try MachO.forEachCommand(data, slice: slice) { cmd, size, at in
                if cmd == MachO.LC_ENCRYPTION_INFO || cmd == MachO.LC_ENCRYPTION_INFO_64 {
                    if let cryptid = try? MachO.u32(data, at + 16), cryptid != 0 { encrypted = true }
                    return
                }
                guard MachO.dylibCommands.contains(cmd) else { return }
                let nameOffset = Int(try MachO.u32(data, at + 8))
                guard nameOffset < size else { return }
                let path = MachO.cString(data, at: at + nameOffset, limit: size - nameOffset)
                guard !path.isEmpty, !seen.contains(path) else { return }
                seen.insert(path)
                dylibs.append(DylibRef(path: path, isWeak: cmd == MachO.LC_LOAD_WEAK_DYLIB))
            }
        }
        return MachOInfo(architectures: architectures, isEncrypted: encrypted, dylibs: dylibs)
    }
}
