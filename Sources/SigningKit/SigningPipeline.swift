import Foundation

public struct SigningRequest {
    public var ipa: URL
    public var profileURL: URL
    public var identitySHA1: String
    public var edits: InfoPlistEdits
    public var dylibs: [URL]
    public var iconImage: URL?
    /// Tweak resource bundles (e.g. extracted from a .deb) copied into the app root.
    public var resourceBundles: [URL]
    /// Removals / weak-flag changes applied to the unpacked bundle before signing.
    public var bundleEdits: BundleEdits
    /// Inject new dylibs as weak references so a missing file cannot crash the app.
    public var injectWeak: Bool
    public var outputURL: URL?
    public init(ipa: URL, profileURL: URL, identitySHA1: String,
                edits: InfoPlistEdits = .init(), dylibs: [URL] = [],
                iconImage: URL? = nil, resourceBundles: [URL] = [],
                bundleEdits: BundleEdits = .init(),
                injectWeak: Bool = true, outputURL: URL? = nil) {
        self.ipa = ipa; self.profileURL = profileURL; self.identitySHA1 = identitySHA1
        self.edits = edits; self.dylibs = dylibs; self.iconImage = iconImage
        self.resourceBundles = resourceBundles; self.bundleEdits = bundleEdits; self.injectWeak = injectWeak; self.outputURL = outputURL
    }
}

public struct SigningResult {
    public let outputURL: URL
    public let teamIdentifier: String
    public let authority: String
    public let signedComponentCount: Int
}

public enum PipelineEvent: CustomStringConvertible {
    case unpacking, editingMetadata, embeddingProfile, extractingEntitlements
    case editingBundle(String), replacingIcon, injecting(String), signing(String)
    case repacking, verifying, done(URL)
    public var description: String {
        switch self {
        case .unpacking: return "Unpacking IPA"
        case .editingMetadata: return "Editing Info.plist"
        case .embeddingProfile: return "Embedding provisioning profile"
        case .extractingEntitlements: return "Extracting entitlements"
        case .editingBundle(let d): return d
        case .replacingIcon: return "Replacing icon"
        case .injecting(let c): return "Injecting \(c)"
        case .signing(let c): return "Signing \(c)"
        case .repacking: return "Repacking IPA"
        case .verifying: return "Verifying signature"
        case .done(let url): return "Done: \(url.lastPathComponent)"
        }
    }
}

public enum SigningError: Error, LocalizedError {
    case profileExpired
    case identityProfileMismatch
    case verificationFailed(String)
    public var errorDescription: String? {
        switch self {
        case .profileExpired: return "The provisioning profile has expired."
        case .identityProfileMismatch: return "The selected identity is not authorized by this profile."
        case .verificationFailed(let d): return "Signature verification failed: \(d)"
        }
    }
}

/// Orchestrates the full re-sign pipeline. All steps run against absolute paths in a
/// temp work directory that is always cleaned up.
public struct SigningPipeline {
    private let codesigner: Codesigner
    private let runner: ProcessRunner
    public init(codesigner: Codesigner = .init(), runner: ProcessRunner = .init()) {
        self.codesigner = codesigner
        self.runner = runner
    }

    /// `<dir>/<ipa-basename>_Signed.ipa` — derived from the input filename, not the app name.
    public static func defaultOutputURL(forIPA ipa: URL) -> URL {
        let base = ipa.deletingPathExtension().lastPathComponent
        return ipa.deletingLastPathComponent().appendingPathComponent("\(base)_Signed.ipa")
    }

    private static func uniqueOutput(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stamp = DateFormatter.stamp.string(from: Date())
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(stamp).ipa")
    }

    public func sign(_ request: SigningRequest,
                     progress: ((PipelineEvent) -> Void)? = nil) throws -> SigningResult {
        let profile = try ProvisioningProfile.parse(data: Data(contentsOf: request.profileURL))
        guard !profile.isExpired else { throw SigningError.profileExpired }
        guard profile.developerCertificateSHA1s
                .map({ $0.uppercased() })
                .contains(request.identitySHA1.uppercased()) else {
            throw SigningError.identityProfileMismatch
        }

        progress?(.unpacking)
        let pkg = try IPAPackage.unpack(ipa: request.ipa, runner: runner)
        defer { pkg.cleanup() }
        let app = pkg.appURL
        let fm = FileManager.default

        if !request.edits.isEmpty {
            progress?(.editingMetadata)
            try InfoPlistEditor(url: app.appendingPathComponent("Info.plist")).apply(request.edits)
        }

        progress?(.embeddingProfile)
        for entry in (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? []
        where entry.pathExtension == "mobileprovision" {
            try? fm.removeItem(at: entry)
        }
        let embedded = app.appendingPathComponent("embedded.mobileprovision")
        try? fm.removeItem(at: embedded)
        try fm.copyItem(at: request.profileURL, to: embedded)

        if !request.bundleEdits.isEmpty {
            try BundleEditor().apply(request.bundleEdits, to: app) { line in
                progress?(.editingBundle(line))
            }
        }

        if !request.resourceBundles.isEmpty {
            try BundleEditor().installResourceBundles(request.resourceBundles, into: app) { line in
                progress?(.editingBundle(line))
            }
        }

        if !request.dylibs.isEmpty {
            let frameworks = app.appendingPathComponent("Frameworks")
            try? fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
            let exeName = (try? InfoPlistEditor(url: app.appendingPathComponent("Info.plist"))
                .string(forKey: "CFBundleExecutable")) ?? nil
            let mainBinary = app.appendingPathComponent(exeName ?? app.deletingPathExtension().lastPathComponent)
            for dylib in request.dylibs {
                let name = dylib.lastPathComponent
                progress?(.injecting(name))
                let dest = frameworks.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: dylib, to: dest)
                try MachOInjector.inject(dylibPath: "@executable_path/Frameworks/\(name)",
                                         into: mainBinary, weak: request.injectWeak)
            }
        }

        if let iconImage = request.iconImage {
            progress?(.replacingIcon)
            try IconInstaller().install(source: iconImage, appURL: app)
        }

        progress?(.extractingEntitlements)
        let entURL = pkg.workDir.appendingPathComponent("entitlements.plist")
        try codesigner.writeEntitlements(profile, to: entURL)

        let components = try IPAPackage.signableComponents(appURL: app)
        for component in components {
            progress?(.signing(component.lastPathComponent))
            let ext = component.pathExtension
            let useEnt = (ext == "app" || ext == "appex") ? entURL : nil
            try codesigner.sign(component, identitySHA1: request.identitySHA1, entitlements: useEnt)
        }

        progress?(.verifying)
        do { try codesigner.verify(app) }
        catch { throw SigningError.verificationFailed(error.localizedDescription) }
        let info = try codesigner.inspect(app)

        progress?(.repacking)
        let output = Self.uniqueOutput(request.outputURL ?? Self.defaultOutputURL(forIPA: request.ipa))
        try pkg.repack(to: output, runner: runner)

        progress?(.done(output))
        return SigningResult(outputURL: output,
                             teamIdentifier: info.teamIdentifier,
                             authority: info.authority,
                             signedComponentCount: components.count)
    }
}

private extension DateFormatter {
    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()
}
