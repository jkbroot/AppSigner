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

    /// Which CLI generation `ideviceinstaller` exposes: 1.2.0 replaced the legacy
    /// `-i/--install` flag with the `install PATH` subcommand.
    public enum InstallCLI: Equatable {
        case subcommand
        case legacyFlag
    }

    public static func installArguments(ipaPath: String, udid: String?, cli: InstallCLI = .subcommand) -> [String] {
        let device = udid.map { ["-u", $0] } ?? []
        switch cli {
        case .subcommand: return device + ["install", ipaPath]
        case .legacyFlag: return device + ["-i", ipaPath]
        }
    }

    /// Detects the CLI generation from `ideviceinstaller --help` output: releases
    /// up to 1.1.x list `-i, --install`, 1.2.0 and later do not. The help text is
    /// a more reliable marker than the version number, which distro builds patch.
    /// The legacy form targets 1.1.x, where `-u` selects the device; 1.0.x used `-U`.
    public static func installCLI(helpOutput: String) -> InstallCLI {
        helpOutput.contains("-i, --install") ? .legacyFlag : .subcommand
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

    /// Probes the installed `ideviceinstaller` to pick the argument form it
    /// understands; falls back to the current subcommand CLI when probing fails.
    /// Both streams are read because `--help` has moved between them upstream.
    /// One extra process per install, so the result is deliberately not cached.
    private func detectCLI(installer: String) -> InstallCLI {
        guard let probe = try? runner.run(installer, ["--help"]) else { return .subcommand }
        return Self.installCLI(helpOutput: probe.stdout + probe.stderr)
    }

    /// Installs the IPA. `udid` nil installs to the only/first connected device.
    public func install(ipa: URL, udid: String?, progress: ((String) -> Void)? = nil) throws {
        guard let installer = Self.findTool("ideviceinstaller") else {
            throw DeviceError.toolMissing("ideviceinstaller")
        }
        let cli = detectCLI(installer: installer)
        let args = Self.installArguments(ipaPath: ipa.path, udid: udid, cli: cli)
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
