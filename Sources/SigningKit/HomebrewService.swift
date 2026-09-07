import Foundation

/// Detects, installs, and updates Homebrew formulae that provide the optional
/// device-install tools (libimobiledevice / ideviceinstaller). The app never
/// auto-installs — it surfaces status and runs install/upgrade only on the user's
/// explicit action.
public struct HomebrewService {
    /// The formulae AppSigner depends on for on-device installation.
    public static let requiredFormulae = ["libimobiledevice", "ideviceinstaller"]
    public static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    private let runner: ProcessRunner
    public init(runner: ProcessRunner = .init()) { self.runner = runner }

    public enum BrewError: Error, LocalizedError {
        case brewMissing
        public var errorDescription: String? {
            switch self {
            case .brewMissing:
                return "Homebrew is not installed. Install it from https://brew.sh, then try again."
            }
        }
    }

    // MARK: Pure helpers

    /// Formula names from `brew outdated` output (first token of each non-empty line).
    public static func parseOutdated(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
    }

    /// First token that looks like a dotted version (e.g. "1.1.1") in a tool's `--version` output.
    public static func parseVersion(_ output: String) -> String? {
        for token in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if t.range(of: "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil {
                return t
            }
        }
        return nil
    }

    public static func installArguments(_ formulae: [String]) -> [String] { ["install"] + formulae }
    public static func upgradeArguments(_ formulae: [String]) -> [String] { ["upgrade"] + formulae }

    public static func findBrew(searchPaths: [String] = searchPaths) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent("brew")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Live queries / actions

    public var brewPath: String? { Self.findBrew() }
    public var isBrewAvailable: Bool { brewPath != nil }

    /// Installed version of a tool via `<tool> --version` (checks stdout+stderr).
    public func installedVersion(ofTool tool: String) -> String? {
        guard let path = DeviceService.findTool(tool) else { return nil }
        guard let r = try? runner.run(path, ["--version"]) else { return nil }
        return Self.parseVersion(r.stdout + "\n" + r.stderr)
    }

    /// Names among `formulae` that Homebrew reports as outdated.
    public func outdatedFormulae(_ formulae: [String] = requiredFormulae) throws -> [String] {
        guard let brew = brewPath else { throw BrewError.brewMissing }
        let out = try runner.run(brew, ["outdated"] + formulae).stdout
        let outdated = Set(Self.parseOutdated(out))
        return formulae.filter { outdated.contains($0) }
    }

    public func install(_ formulae: [String] = requiredFormulae, progress: ((String) -> Void)? = nil) throws {
        try runBrew(Self.installArguments(formulae), progress: progress)
    }

    public func upgrade(_ formulae: [String] = requiredFormulae, progress: ((String) -> Void)? = nil) throws {
        try runBrew(Self.upgradeArguments(formulae), progress: progress)
    }

    private func runBrew(_ args: [String], progress: ((String) -> Void)?) throws {
        guard let brew = brewPath else { throw BrewError.brewMissing }
        let code = try runner.runStreaming(brew, args) { progress?($0) }
        guard code == 0 else { throw ProcessRunner.ProcessError.failed(command: "brew " + args.joined(separator: " "), exitCode: code, stderr: "") }
    }
}
