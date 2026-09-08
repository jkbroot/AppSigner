import Foundation

/// One problem (or note) found before signing.
public struct PreflightFinding: Identifiable, Equatable {
    public enum Severity: String, Comparable {
        case error, warning, info
        private var order: Int { self == .error ? 0 : (self == .warning ? 1 : 2) }
        public static func < (a: Severity, b: Severity) -> Bool { a.order < b.order }
    }
    /// Stable code for the check (useful for tests and UI keys).
    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
}

/// Everything the checks need. All fields are optional so the validator can run as soon
/// as the user has picked anything at all.
public struct PreflightInput {
    public var report: BundleReport?
    public var profile: ProvisioningProfile?
    public var identitySHA1: String?
    /// The bundle id that will actually be signed (after any user edit).
    public var bundleID: String?
    public var deviceUDID: String?
    /// Entitlements the app is signed with today, used to spot ones the profile will drop.
    public var originalEntitlements: [String: Any]?
    /// Bundle ids that the loaded tweak packages declare they target.
    public var tweakTargetBundleIDs: [String] = []
    /// A loaded tweak package depends on Substrate / ElleKit.
    public var tweakRequiresSubstrate = false
    /// Extensions given their own profile: bundle-relative appex path -> that profile's app-id.
    public var extensionProfileAppIDs: [String: String] = [:]

    public init(report: BundleReport? = nil, profile: ProvisioningProfile? = nil,
                identitySHA1: String? = nil, bundleID: String? = nil,
                deviceUDID: String? = nil, originalEntitlements: [String: Any]? = nil) {
        self.report = report; self.profile = profile; self.identitySHA1 = identitySHA1
        self.bundleID = bundleID; self.deviceUDID = deviceUDID
        self.originalEntitlements = originalEntitlements
    }
}

/// Pure, app-agnostic checks that run before signing. Findings are advisory: the signing
/// pipeline still enforces the hard failures itself, so a false positive never blocks a run.
public struct PreflightValidator {
    public init() {}

    /// Entitlement keys codesign always rewrites from the profile — never "dropped".
    private static let rewrittenEntitlements: Set<String> = [
        "application-identifier", "com.apple.developer.team-identifier",
        "get-task-allow", "keychain-access-groups",
    ]

    private static let expiringSoonWindow: TimeInterval = 30 * 24 * 3600

    public func validate(_ input: PreflightInput) -> [PreflightFinding] {
        var findings: [PreflightFinding] = []
        func add(_ id: String, _ severity: PreflightFinding.Severity, _ title: String, _ detail: String) {
            findings.append(PreflightFinding(id: id, severity: severity, title: title, detail: detail))
        }

        // --- The binary itself ---
        if let report = input.report {
            if report.isEncrypted {
                add("encrypted", .error, "App binary is FairPlay-encrypted",
                    "This IPA came straight from the App Store. Re-signing it will succeed but the app will not launch — use a decrypted build.")
            }

            let main = report.binaries.first { $0.role == .mainExecutable }
            if let archs = main?.architectures, !archs.isEmpty,
               !archs.contains(where: { $0.hasPrefix("arm64") }) {
                add("noArm64", .warning, "No arm64 slice",
                    "The main binary only has \(archs.joined(separator: ", ")); it will not run on modern iPhones.")
            }

            let dylibs = report.binaries.flatMap(\.dylibs)
            let missingStrong = dylibs.filter { $0.kind == .missing && !$0.isWeak }
            if !missingStrong.isEmpty {
                add("missingDylibs", .warning, "\(missingStrong.count) missing librar\(missingStrong.count == 1 ? "y" : "ies")",
                    "Referenced but not present: \(names(missingStrong)). The app will crash on launch unless you remove these references or make them weak.")
            }
            let missingWeak = dylibs.filter { $0.kind == .missing && $0.isWeak }
            if !missingWeak.isEmpty {
                add("missingWeakDylibs", .info, "\(missingWeak.count) missing weak reference\(missingWeak.count == 1 ? "" : "s")",
                    "Weakly linked and absent: \(names(missingWeak)). The app still launches; those features simply do nothing.")
            }
            let jailbreak = dylibs.filter { $0.kind == .jailbreak }
            if !jailbreak.isEmpty {
                add("jailbreakReferences", .warning, "\(jailbreak.count) jailbreak-only reference\(jailbreak.count == 1 ? "" : "s")",
                    "These paths only exist on a jailbroken device: \(names(jailbreak)).")
            }
        }

        // --- Tweak packages ---
        if !input.tweakTargetBundleIDs.isEmpty, let bundleID = input.bundleID,
           !input.tweakTargetBundleIDs.contains(bundleID) {
            add("tweakTargetMismatch", .warning, "Tweak targets a different app",
                "The package declares it patches \(input.tweakTargetBundleIDs.joined(separator: ", ")), but you are signing '\(bundleID)'. It will load and do nothing.")
        }
        if input.tweakRequiresSubstrate {
            let hasSubstrate = (input.report?.items ?? []).contains {
                $0.name.lowercased().contains("substrate") || $0.name.lowercased().contains("ellekit")
            }
            if !hasSubstrate {
                add("substrateMissing", .warning, "Tweak needs Substrate, which the app does not bundle",
                    "This package depends on CydiaSubstrate / ElleKit. On a non-jailbroken device the tweak will not run unless the app already ships a Substrate replacement.")
            }
        }

        // --- Profile ---
        if let profile = input.profile {
            if profile.isExpired {
                add("profileExpired", .error, "Provisioning profile has expired",
                    "It expired on \(dateText(profile.expirationDate)). Download a fresh profile before signing.")
            } else if let expiry = profile.expirationDate,
                      expiry.timeIntervalSinceNow < Self.expiringSoonWindow {
                add("profileExpiringSoon", .warning, "Profile expires soon",
                    "It expires on \(dateText(expiry)); apps signed with it stop working then.")
            }

            if let sha1 = input.identitySHA1,
               !profile.developerCertificateSHA1s.map({ $0.uppercased() }).contains(sha1.uppercased()) {
                add("identityMismatch", .error, "Identity is not authorized by this profile",
                    "The selected certificate is not one of the profile's developer certificates, so the signed app will be rejected.")
            }

            // Explicit (non-wildcard) app ids must match the bundle id exactly.
            let suffix = appIDSuffix(profile.applicationIdentifier, team: profile.teamIdentifier)
            if let suffix, suffix != "*" {
                if let bundleID = input.bundleID, bundleID != suffix {
                    add("bundleIDMismatch", .error, "Bundle ID does not match the profile",
                        "The profile only covers '\(suffix)' but the app will be signed as '\(bundleID)'. Change the Bundle ID or use a wildcard profile.")
                }
                let extensions = input.report?.items.filter { $0.kind == .appExtension } ?? []
                let uncovered = extensions.filter { input.extensionProfileAppIDs[$0.id] == nil }
                if !uncovered.isEmpty {
                    add("extensionsNeedOwnProfiles", .warning, "\(uncovered.count) app extension\(uncovered.count == 1 ? "" : "s") without a profile",
                        "Each extension has its own bundle id and needs its own profile: \(uncovered.map(\.name).joined(separator: ", ")). Assign one in Contents, remove the extension, or use a wildcard profile.")
                }
                // An assigned profile must actually cover that extension's bundle id.
                for item in extensions {
                    guard let appID = input.extensionProfileAppIDs[item.id],
                          let suffix = appIDSuffix(appID, team: profile.teamIdentifier),
                          suffix != "*", let bundleID = item.bundleID, suffix != bundleID
                    else { continue }
                    add("extensionProfileMismatch", .error, "Extension profile does not match",
                        "\(item.name) is '\(bundleID)' but its assigned profile only covers '\(suffix)'.")
                }
            }

            if let udid = input.deviceUDID, !profile.provisionedDevices.isEmpty,
               !profile.provisionedDevices.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
                add("deviceNotProvisioned", .warning, "Selected device is not in the profile",
                    "This profile lists \(profile.provisionedDevices.count) device(s) and the connected one is not among them; the install will be refused.")
            }

            if let original = input.originalEntitlements {
                let granted = Set(profile.entitlements.keys)
                let dropped = original.keys
                    .filter { !Self.rewrittenEntitlements.contains($0) && !granted.contains($0) }
                    .sorted()
                if !dropped.isEmpty {
                    add("droppedEntitlements", .warning, "\(dropped.count) entitlement\(dropped.count == 1 ? "" : "s") will be dropped",
                        "Your profile does not grant: \(dropped.joined(separator: ", ")). Those capabilities stop working after re-signing.")
                }
            }
        }

        return findings.sorted { $0.severity < $1.severity }
    }

    // MARK: Helpers

    /// "TEAM.com.x.app" -> "com.x.app"; "TEAM.*" -> "*".
    private func appIDSuffix(_ applicationIdentifier: String, team: String) -> String? {
        let prefix = team + "."
        guard applicationIdentifier.hasPrefix(prefix) else { return nil }
        return String(applicationIdentifier.dropFirst(prefix.count))
    }

    private func names(_ dylibs: [ResolvedDylib]) -> String {
        dylibs.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "an unknown date" }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: date)
    }
}
