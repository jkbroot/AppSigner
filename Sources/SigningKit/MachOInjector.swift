import Foundation

/// Injects an `LC_LOAD_DYLIB` load command into a Mach-O binary natively (no optool).
/// Writes the command into the existing header padding and bumps `ncmds`/`sizeofcmds`,
/// so the file size and all section offsets stay unchanged. Handles thin 64-bit
/// (little-endian) and fat binaries. The stale code signature (if any) is left for the
/// caller to re-sign afterwards.
public enum MachOInjector {
    public enum InjectError: Error, LocalizedError, Equatable {
        case notMachO, unsupportedArch, noHeaderSpace
        public var errorDescription: String? {
            switch self {
            case .notMachO: return "Not a Mach-O file."
            case .unsupportedArch: return "Unsupported Mach-O architecture (need 64-bit)."
            case .noHeaderSpace: return "Not enough header padding to inject the dylib load command."
            }
        }
    }

    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let FAT_MAGIC_64: UInt32 = 0xCAFEBABF
    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let LC_LOAD_DYLIB: UInt32 = 0x0C
    private static let LC_SEGMENT_64: UInt32 = 0x19

    public static func inject(dylibPath: String, into url: URL) throws {
        var data = try Data(contentsOf: url)
        guard data.count >= 8 else { throw InjectError.notMachO }

        let magicBE = try readU32(data, 0, bigEndian: true)
        if magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 {
            try injectFat(&data, is64: magicBE == FAT_MAGIC_64, dylibPath: dylibPath)
        } else if try readU32(data, 0, bigEndian: false) == MH_MAGIC_64 {
            try injectThin(&data, base: 0, dylibPath: dylibPath)
        } else {
            throw InjectError.notMachO
        }
        try data.write(to: url)
    }

    // MARK: Fat

    private static func injectFat(_ data: inout Data, is64: Bool, dylibPath: String) throws {
        let nfat = try readU32(data, 4, bigEndian: true)
        var archOff = 8
        for _ in 0..<nfat {
            let sliceOffset: Int
            if is64 {
                sliceOffset = Int(try readU64(data, archOff + 8, bigEndian: true))
                archOff += 32
            } else {
                sliceOffset = Int(try readU32(data, archOff + 8, bigEndian: true))
                archOff += 20
            }
            try injectThin(&data, base: sliceOffset, dylibPath: dylibPath)
        }
    }

    // MARK: Thin (64-bit little-endian)

    private static func injectThin(_ data: inout Data, base: Int, dylibPath: String) throws {
        guard try readU32(data, base, bigEndian: false) == MH_MAGIC_64 else {
            throw InjectError.unsupportedArch
        }
        let headerSize = 32
        let ncmds = try readU32(data, base + 16, bigEndian: false)
        let sizeofcmds = try readU32(data, base + 20, bigEndian: false)
        let loadStart = base + headerSize
        let loadEnd = loadStart + Int(sizeofcmds)

        // Smallest section file offset marks where the header padding ends.
        var minSectionOffset = Int.max
        var p = loadStart
        for _ in 0..<ncmds {
            let cmd = try readU32(data, p, bigEndian: false)
            let cmdsize = Int(try readU32(data, p + 4, bigEndian: false))
            guard cmdsize > 0, p + cmdsize <= data.count else { throw InjectError.notMachO }
            if cmd == LC_SEGMENT_64 {
                let nsects = Int(try readU32(data, p + 64, bigEndian: false))
                var sp = p + 72
                for _ in 0..<nsects {
                    let off = Int(try readU32(data, sp + 48, bigEndian: false))
                    if off > 0 { minSectionOffset = min(minSectionOffset, off) }
                    sp += 80
                }
            }
            p += cmdsize
        }

        let firstContent = (minSectionOffset == Int.max) ? loadEnd - base : minSectionOffset
        let slack = firstContent - (headerSize + Int(sizeofcmds))

        let pathBytes = Array(dylibPath.utf8)
        let cmdSize = ((24 + pathBytes.count + 1) + 7) & ~7   // align to 8
        guard cmdSize <= slack else { throw InjectError.noHeaderSpace }

        var cmd = Data()
        appendU32(&cmd, LC_LOAD_DYLIB)      // cmd
        appendU32(&cmd, UInt32(cmdSize))    // cmdsize
        appendU32(&cmd, 24)                 // dylib.name.offset
        appendU32(&cmd, 2)                  // timestamp
        appendU32(&cmd, 0)                  // current_version
        appendU32(&cmd, 0)                  // compatibility_version
        cmd.append(contentsOf: pathBytes)
        cmd.append(0)
        while cmd.count < cmdSize { cmd.append(0) }

        // Overwrite the header padding with the new command (no length change).
        let writeAt = loadEnd
        let start = data.startIndex + writeAt
        data.replaceSubrange(start..<(start + cmdSize), with: cmd)

        try writeU32(&data, base + 16, ncmds + 1, bigEndian: false)
        try writeU32(&data, base + 20, sizeofcmds + UInt32(cmdSize), bigEndian: false)
    }

    // MARK: Byte helpers (offsets are relative to data.startIndex)

    private static func readU32(_ d: Data, _ off: Int, bigEndian: Bool) throws -> UInt32 {
        let s = d.startIndex + off
        guard off >= 0, s + 4 <= d.endIndex else { throw InjectError.notMachO }
        let b = [UInt8](d[s..<s+4])
        let v = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return bigEndian ? v.byteSwapped : v
    }

    private static func readU64(_ d: Data, _ off: Int, bigEndian: Bool) throws -> UInt64 {
        let s = d.startIndex + off
        guard off >= 0, s + 8 <= d.endIndex else { throw InjectError.notMachO }
        let b = [UInt8](d[s..<s+8])
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }
        return bigEndian ? v.byteSwapped : v
    }

    private static func writeU32(_ d: inout Data, _ off: Int, _ value: UInt32, bigEndian: Bool) throws {
        let s = d.startIndex + off
        guard off >= 0, s + 4 <= d.endIndex else { throw InjectError.notMachO }
        let v = bigEndian ? value.byteSwapped : value
        let bytes: [UInt8] = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        d.replaceSubrange(s..<s+4, with: bytes)
    }

    private static func appendU32(_ d: inout Data, _ value: UInt32) {
        d.append(UInt8(value & 0xff))
        d.append(UInt8((value >> 8) & 0xff))
        d.append(UInt8((value >> 16) & 0xff))
        d.append(UInt8((value >> 24) & 0xff))
    }
}
