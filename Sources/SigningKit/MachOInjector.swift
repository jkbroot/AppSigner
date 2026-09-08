import Foundation

/// Adds, removes and re-flags `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` load commands in a
/// Mach-O binary — natively, without `optool` or `install_name_tool`.
///
/// All edits stay inside the Mach-O header region: injection writes into the existing
/// header padding and removal compacts the load commands and re-zeroes the freed tail.
/// File size and every section offset therefore stay unchanged, so the binary remains
/// valid; the (now stale) signature is replaced by the caller's re-sign step.
///
/// Thin and fat files are both supported. 64-bit slices are edited; 32-bit slices can be
/// removed from / re-flagged too, but cannot be injected into (their segment layout is
/// not handled) and are skipped rather than failing the whole file.
public enum MachOInjector {
    public enum InjectError: Error, LocalizedError, Equatable {
        case notMachO, unsupportedArch, noHeaderSpace, dylibNotFound
        public var errorDescription: String? {
            switch self {
            case .notMachO: return "Not a Mach-O file."
            case .unsupportedArch: return "No 64-bit Mach-O slice to modify."
            case .noHeaderSpace: return "Not enough header padding to inject the dylib load command."
            case .dylibNotFound: return "That dylib reference was not found in the binary."
            }
        }
    }

    // MARK: Inject

    /// Adds a load command for `dylibPath`. `weak` uses `LC_LOAD_WEAK_DYLIB`, so the app
    /// still launches when the library is missing — the safer default for tweaks.
    public static func inject(dylibPath: String, into url: URL, weak: Bool = false) throws {
        var data = try Data(contentsOf: url)
        let slices = try MachO.slices(in: data)
        guard !slices.isEmpty else { throw InjectError.notMachO }

        var injected = false
        for slice in slices where slice.is64 {
            try injectIntoSlice(&data, slice: slice, dylibPath: dylibPath, weak: weak)
            injected = true
        }
        guard injected else { throw InjectError.unsupportedArch }
        try data.write(to: url)
    }

    private static func injectIntoSlice(_ data: inout Data, slice: MachO.Slice,
                                        dylibPath: String, weak: Bool) throws {
        let sizeofcmds = try MachO.u32(data, slice.offset + 20)
        let ncmds = try MachO.u32(data, slice.offset + 16)
        let loadEnd = slice.offset + slice.headerSize + Int(sizeofcmds)

        // Header padding runs until the first section's file offset.
        var minSectionOffset = Int.max
        try MachO.forEachCommand(data, slice: slice) { cmd, _, at in
            guard cmd == 0x19 else { return }                    // LC_SEGMENT_64
            let nsects = Int(try MachO.u32(data, at + 64))
            var sp = at + 72
            for _ in 0..<nsects {
                let off = Int(try MachO.u32(data, sp + 48))
                if off > 0 { minSectionOffset = min(minSectionOffset, off) }
                sp += 80
            }
        }
        let firstContent = (minSectionOffset == Int.max) ? Int(sizeofcmds) + slice.headerSize : minSectionOffset
        let slack = firstContent - (slice.headerSize + Int(sizeofcmds))

        let pathBytes = Array(dylibPath.utf8)
        let cmdSize = ((24 + pathBytes.count + 1) + 7) & ~7
        guard cmdSize <= slack else { throw InjectError.noHeaderSpace }

        var command = Data()
        append(&command, weak ? MachO.LC_LOAD_WEAK_DYLIB : MachO.LC_LOAD_DYLIB)
        append(&command, UInt32(cmdSize))
        append(&command, 24)   // dylib.name offset
        append(&command, 2)    // timestamp
        append(&command, 0)    // current_version
        append(&command, 0)    // compatibility_version
        command.append(contentsOf: pathBytes)
        command.append(0)
        while command.count < cmdSize { command.append(0) }

        let start = data.startIndex + loadEnd
        data.replaceSubrange(start..<(start + cmdSize), with: command)
        try MachO.writeU32(&data, slice.offset + 16, ncmds + 1)
        try MachO.writeU32(&data, slice.offset + 20, sizeofcmds + UInt32(cmdSize))
    }

    // MARK: Remove

    /// Removes every load command referencing `path`, in every slice that has one.
    public static func removeDylib(path: String, from url: URL) throws {
        var data = try Data(contentsOf: url)
        let slices = try MachO.slices(in: data)
        guard !slices.isEmpty else { throw InjectError.notMachO }

        var removed = false
        // Slices are edited in place and keep their offsets (no length change).
        for slice in slices {
            while let found = try findCommand(data, slice: slice, path: path) {
                try removeCommand(&data, slice: slice, at: found.offset, size: found.size)
                removed = true
            }
        }
        guard removed else { throw InjectError.dylibNotFound }
        try data.write(to: url)
    }

    private static func removeCommand(_ data: inout Data, slice: MachO.Slice,
                                      at cmdOffset: Int, size: Int) throws {
        let ncmds = try MachO.u32(data, slice.offset + 16)
        let sizeofcmds = try MachO.u32(data, slice.offset + 20)
        let loadEnd = slice.offset + slice.headerSize + Int(sizeofcmds)

        // Shift the following commands up over the removed one, then zero the freed tail.
        let tailStart = cmdOffset + size
        if tailStart < loadEnd {
            let tail = data.subdata(in: (data.startIndex + tailStart)..<(data.startIndex + loadEnd))
            data.replaceSubrange((data.startIndex + cmdOffset)..<(data.startIndex + cmdOffset + tail.count),
                                 with: tail)
        }
        let zeroStart = data.startIndex + loadEnd - size
        data.replaceSubrange(zeroStart..<(data.startIndex + loadEnd), with: Data(repeating: 0, count: size))

        try MachO.writeU32(&data, slice.offset + 16, ncmds - 1)
        try MachO.writeU32(&data, slice.offset + 20, sizeofcmds - UInt32(size))
    }

    // MARK: Rewrite a load path

    /// Points an existing reference at a new path, keeping its weak flag.
    ///
    /// The new path is written into the existing command when it fits (the usual case,
    /// since `@rpath/...` is shorter than a jailbreak path). Otherwise the command is
    /// removed and re-injected, which needs header padding like any injection.
    public static func rewriteDylibPath(from oldPath: String, to newPath: String, in url: URL) throws {
        var data = try Data(contentsOf: url)
        let slices = try MachO.slices(in: data)
        guard !slices.isEmpty else { throw InjectError.notMachO }

        var rewritten = false
        var needsReinject: [(weak: Bool, slice: MachO.Slice)] = []

        for slice in slices {
            guard let found = try findCommand(data, slice: slice, path: oldPath) else { continue }
            let cmd = try MachO.u32(data, found.offset)
            let weak = cmd == MachO.LC_LOAD_WEAK_DYLIB
            let nameOffset = Int(try MachO.u32(data, found.offset + 8))
            let available = found.size - nameOffset
            let bytes = Array(newPath.utf8)

            if bytes.count + 1 <= available {
                // Overwrite the string in place and clear the rest of the command.
                var payload = Data(bytes)
                payload.append(contentsOf: [UInt8](repeating: 0, count: available - bytes.count))
                let start = data.startIndex + found.offset + nameOffset
                data.replaceSubrange(start..<(start + available), with: payload)
                rewritten = true
            } else {
                needsReinject.append((weak, slice))
            }
        }

        if !needsReinject.isEmpty {
            try data.write(to: url)
            try removeDylib(path: oldPath, from: url)
            try inject(dylibPath: newPath, into: url, weak: needsReinject[0].weak)
            return
        }
        guard rewritten else { throw InjectError.dylibNotFound }
        try data.write(to: url)
    }

    // MARK: Weak flag

    /// Switches a reference between `LC_LOAD_DYLIB` and `LC_LOAD_WEAK_DYLIB`.
    public static func setWeak(_ weak: Bool, forDylib path: String, in url: URL) throws {
        var data = try Data(contentsOf: url)
        var changed = false
        for slice in try MachO.slices(in: data) {
            if let found = try findCommand(data, slice: slice, path: path) {
                try MachO.writeU32(&data, found.offset,
                                   weak ? MachO.LC_LOAD_WEAK_DYLIB : MachO.LC_LOAD_DYLIB)
                changed = true
            }
        }
        guard changed else { throw InjectError.dylibNotFound }
        try data.write(to: url)
    }

    // MARK: Helpers

    private static func findCommand(_ data: Data, slice: MachO.Slice,
                                    path: String) throws -> (offset: Int, size: Int)? {
        var match: (Int, Int)?
        try MachO.forEachCommand(data, slice: slice) { cmd, size, at in
            guard match == nil, MachO.dylibCommands.contains(cmd) else { return }
            let nameOffset = Int(try MachO.u32(data, at + 8))
            guard nameOffset < size else { return }
            if MachO.cString(data, at: at + nameOffset, limit: size - nameOffset) == path {
                match = (at, size)
            }
        }
        return match
    }

    private static func append(_ d: inout Data, _ value: UInt32) {
        d.append(UInt8(value & 0xff))
        d.append(UInt8((value >> 8) & 0xff))
        d.append(UInt8((value >> 16) & 0xff))
        d.append(UInt8((value >> 24) & 0xff))
    }
}
