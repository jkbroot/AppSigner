import Foundation

/// Lists connected iOS devices and installs an IPA via libimobiledevice
/// (`idevice_id`, `ideviceinfo`, `ideviceinstaller`). Tool paths are resolved
/// explicitly because GUI apps launched from Finder do not inherit the shell PATH.
public struct DeviceService {
    public struct Device: Equatable, Identifiable {
        public let udid: String
        public let name: String
        public var id: String { udid }
        public init(udid: String, name: String) { self.udid = udid; self.name = name }
    }

    public enum DeviceError: Error, LocalizedError {
        case toolMissing(String)
        case installFailed(String)
        public var errorDescription: String? {
            switch self {
            case .toolMissing(let t): return "`\(t)` not found. Install it with: brew install ideviceinstaller"
            case .installFailed(let d): return "Install failed: \(d)"
            }
        }
    }

    /// Directories searched for the libimobiledevice tools (Homebrew arm64/Intel, MacPorts, system).
    public static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    private let runner: ProcessRunner
    public init(runner: ProcessRunner = .init()) { self.runner = runner }

    // MARK: Pure helpers

    public static func parseUDIDs(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func installArguments(ipaPath: String, udid: String?) -> [String] {
        if let udid { return ["-u", udid, "-i", ipaPath] }
        return ["-i", ipaPath]
    }

    public static func findTool(_ name: String, searchPaths: [String] = defaultSearchPaths) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Availability

    public var isAvailable: Bool { Self.findTool("ideviceinstaller") != nil }

    // MARK: Live queries / actions

    public func listDevices() throws -> [Device] {
        guard let idevice = Self.findTool("idevice_id") else { throw DeviceError.toolMissing("idevice_id") }
        let out = try runner.run(idevice, ["-l"]).stdout
        return Self.parseUDIDs(out).map { udid in
            Device(udid: udid, name: deviceName(udid: udid) ?? udid)
        }
    }

    private func deviceName(udid: String) -> String? {
        guard let info = Self.findTool("ideviceinfo") else { return nil }
        let r = try? runner.run(info, ["-u", udid, "-k", "DeviceName"])
        let name = r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }

    /// Installs the IPA. `udid` nil installs to the only/first connected device.
    public func install(ipa: URL, udid: String?, progress: ((String) -> Void)? = nil) throws {
        guard let installer = Self.findTool("ideviceinstaller") else {
            throw DeviceError.toolMissing("ideviceinstaller")
        }
        let args = Self.installArguments(ipaPath: ipa.path, udid: udid)
        let result = try runner.run(installer, args)
        (result.stdout + result.stderr)
            .split(whereSeparator: \.isNewline)
            .forEach { progress?(String($0)) }
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw DeviceError.installFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
