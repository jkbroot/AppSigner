import Foundation

/// Wraps `/usr/bin/codesign` for signing bundles/components and verifying the result.
public struct Codesigner {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .init()) { self.runner = runner }

    /// Signing summary parsed from `codesign -dv`.
    public struct SignatureInfo {
        public let authority: String
        public let teamIdentifier: String
    }

    /// Writes the profile's entitlements to an XML plist for `codesign --entitlements`.
    public func writeEntitlements(_ profile: ProvisioningProfile, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: profile.entitlements, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// Signs one component. Pass `entitlements` only for the app and app extensions;
    /// frameworks and dylibs are signed without entitlements.
    public func sign(_ component: URL, identitySHA1: String, entitlements: URL?) throws {
        var args = ["-f", "-s", identitySHA1]
        if let entitlements { args += ["--entitlements", entitlements.path] }
        args.append(component.path)
        try runner.runThrowing("/usr/bin/codesign", args)
    }

    /// Verifies a signed bundle: `codesign --verify --deep --strict`.
    public func verify(_ bundle: URL) throws {
        try runner.runThrowing("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", bundle.path])
    }

    /// Reads authority + team identifier from a signed bundle.
    public func inspect(_ bundle: URL) throws -> SignatureInfo {
        let r = try runner.run("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path])
        let text = r.stdout + r.stderr   // codesign prints to stderr
        func value(prefix: String) -> String {
            for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            return ""
        }
        // First Authority line is the leaf signing identity.
        let authority = text.split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) } ?? ""
        return SignatureInfo(authority: authority, teamIdentifier: value(prefix: "TeamIdentifier="))
    }
}
