import Foundation

/// Compiles a generated patch source into an injectable dylib for iOS (arm64).
public struct PatchDylibBuilder {
    public enum BuildError: Error, LocalizedError {
        case toolchainMissing, failed(String)
        public var errorDescription: String? {
            switch self {
            case .toolchainMissing: return "The iOS SDK is required. Install Xcode."
            case .failed(let d): return "Could not build the patch: \(d)"
            }
        }
    }

    public static let dylibName = "AppSignerPatches.dylib"

    public static func compileArguments(source: URL, output: URL, sdkPath: String) -> [String] {
        ["-sdk", "iphoneos", "clang",
         "-arch", "arm64", "-dynamiclib", "-fobjc-arc",
         "-isysroot", sdkPath,
         "-mios-version-min=13.0",
         "-framework", "Foundation",
         "-Wl,-headerpad_max_install_names",
         "-install_name", "@executable_path/Frameworks/\(dylibName)",
         "-o", output.path, source.path]
    }

    private let runner: ProcessRunner
    public init(runner: ProcessRunner = .init()) { self.runner = runner }

    /// Generates and compiles the patch dylib, returning its URL.
    public func build(_ patches: [MethodPatch], into directory: URL,
                      progress: ((String) -> Void)? = nil) throws -> URL {
        let sdk = (try? runner.runThrowing("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !sdk.isEmpty else { throw BuildError.toolchainMissing }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("AppSignerPatches.m")
        try Data(PatchGenerator.source(for: patches).utf8).write(to: source)

        let output = directory.appendingPathComponent(Self.dylibName)
        progress?("Building \(patches.count) patch(es)…")
        let code = try runner.runStreaming("/usr/bin/xcrun",
                                           Self.compileArguments(source: source, output: output, sdkPath: sdk)) {
            if $0.contains("error:") { progress?($0) }
        }
        guard code == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw BuildError.failed("clang exited with \(code)")
        }
        return output
    }
}
