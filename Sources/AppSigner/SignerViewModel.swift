import Foundation
import SigningKit

/// A tweak package (.deb) the user loaded.
struct LoadedTweak: Identifiable {
    let id = UUID()
    let info: DebPackage.Info
    let dylibs: [URL]
    let bundles: [URL]
    let targetBundleIDs: [String]
    let requiresSubstrate: Bool
    /// Temporary extraction directory, removed when the tweak is dropped.
    let root: URL
}

/// One line in the process screen.
struct ProcessStep: Identifiable, Equatable {
    enum Status { case pending, active, done, failed }
    let id = UUID()
    let title: String
    var detail: String = ""
    var status: Status
}

/// Observable state + actions bridging SigningKit to the SwiftUI views.
/// All `@Published` mutations are marshalled back to the main queue.
final class SignerViewModel: ObservableObject {

    // Inputs
    @Published var ipaURL: URL?
    @Published var profileURL: URL?

    // Editable metadata (prefilled from the IPA)
    @Published var bundleID: String = ""
    @Published var displayName: String = ""
    @Published var shortVersion: String = ""
    @Published var bundleVersion: String = ""

    // Dylibs to inject
    @Published var dylibs: [URL] = []

    // Replacement icon
    @Published var iconURL: URL?

    // Tweak packages (.deb)
    @Published var tweaks: [LoadedTweak] = []
    var resourceBundles: [URL] { tweaks.flatMap(\.bundles) }

    // Pre-flight
    @Published var showPreflight = false
    @Published private(set) var originalEntitlements: [String: Any]?

    /// Recomputed on every state change — validation is pure and cheap.
    var findings: [PreflightFinding] {
        var input = PreflightInput(
            report: report,
            profile: profile,
            identitySHA1: selectedIdentitySHA1,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            deviceUDID: installAfterSign ? selectedDeviceUDID : nil,
            originalEntitlements: originalEntitlements)
        input.tweakTargetBundleIDs = Array(Set(tweaks.flatMap(\.targetBundleIDs))).sorted()
        input.tweakRequiresSubstrate = tweaks.contains { $0.requiresSubstrate }
        return PreflightValidator().validate(input)
    }
    var errorCount: Int { findings.filter { $0.severity == .error }.count }
    var warningCount: Int { findings.filter { $0.severity == .warning }.count }
    var canRunPreflight: Bool { ipaURL != nil && profileURL != nil }

    // Contents explorer (inspect + removals)
    @Published var showContents = false
    @Published var inspecting = false
    @Published var report: BundleReport?
    @Published var removedItems: Set<String> = []        // BundleItem.id
    @Published var removedDylibKeys: Set<String> = []    // "binary|dylib"
    @Published var weakenedDylibKeys: Set<String> = []
    @Published var injectWeak = true

    static func dylibKey(_ binary: String, _ dylib: String) -> String { "\(binary)|\(dylib)" }
    private static func splitKey(_ key: String) -> DylibEdit? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return DylibEdit(binaryPath: parts[0], dylibPath: parts[1])
    }

    /// Unpacks the selected IPA into a temporary copy and inspects it (read-only).
    func inspectIPA() {
        guard let ipaURL, !inspecting else { return }
        inspecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            var scanned: BundleReport?
            var entitlements: [String: Any]?
            if let pkg = try? IPAPackage.unpack(ipa: ipaURL) {
                scanned = try? BundleInspector().inspect(appURL: pkg.appURL)
                entitlements = Codesigner().entitlements(of: pkg.appURL)
                pkg.cleanup()
            }
            DispatchQueue.main.async {
                self.originalEntitlements = entitlements
                self.report = scanned
                self.inspecting = false
                if scanned == nil { self.errorMessage = "Could not read the app bundle." }
            }
        }
    }

    /// Edits derived from the current selection. Removing a dylib reference also drops the
    /// library file when nothing else in the bundle still references it.
    var bundleEdits: BundleEdits {
        var edits = BundleEdits()
        edits.removedDylibs = removedDylibKeys.compactMap(Self.splitKey)
        edits.weakenedDylibs = weakenedDylibKeys.compactMap(Self.splitKey)

        var paths = removedItems
        if let report {
            for edit in edits.removedDylibs {
                guard let resolved = report.binaries.first(where: { $0.id == edit.binaryPath })?
                    .dylibs.first(where: { $0.path == edit.dylibPath })?.resolvedRelativePath else { continue }
                let others = (report.referrers[resolved] ?? []).filter { $0 != edit.binaryPath }
                if others.isEmpty { paths.insert(resolved) }
            }
        }
        edits.removedPaths = Array(paths)
        return edits
    }

    var removalSummary: String? {
        let edits = bundleEdits
        guard !edits.isEmpty else { return nil }
        var parts: [String] = []
        if !edits.removedDylibs.isEmpty { parts.append("\(edits.removedDylibs.count) dylib refs") }
        if !edits.removedPaths.isEmpty { parts.append("\(edits.removedPaths.count) files") }
        if !edits.weakenedDylibs.isEmpty { parts.append("\(edits.weakenedDylibs.count) weakened") }
        let freed = estimatedFreedBytes
        let size = freed > 0 ? " · frees ~\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))" : ""
        return "Will remove: " + parts.joined(separator: ", ") + size
    }

    var estimatedFreedBytes: Int64 {
        guard let report else { return 0 }
        let paths = Set(bundleEdits.removedPaths)
        return report.items.filter { paths.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    func clearContentsSelection() {
        removedItems.removeAll(); removedDylibKeys.removeAll(); weakenedDylibKeys.removeAll()
    }

    // Identity / profile
    @Published var identities: [SigningIdentity] = []
    @Published var matchedIdentities: [SigningIdentity] = []
    @Published var selectedIdentitySHA1: String?
    @Published var profile: ProvisioningProfile?

    // Device install
    @Published var devices: [DeviceService.Device] = []
    @Published var selectedDeviceUDID: String?
    @Published var installAfterSign = false
    @Published var deviceToolsAvailable = false
    @Published var brewAvailable = false
    @Published var toolVersion: String?
    @Published var toolUpdateMessage: String?
    @Published var toolUpdateAvailable = false
    @Published var toolCheckBusy = false

    // Process screen state
    @Published var isRunning = false
    @Published var showProcess = false
    @Published var steps: [ProcessStep] = []
    @Published var log: [String] = []
    @Published var resultURL: URL?
    @Published var errorMessage: String?

    private var originalInfo: IPAPackage.AppInfo?
    private var signCount = 0

    var isReadyToSign: Bool {
        ipaURL != nil && profileURL != nil && selectedIdentitySHA1 != nil && !isRunning
    }

    // MARK: Derived text

    var appBundleName: String { originalInfo?.appBundleName ?? "—" }

    var profileSummary: String {
        guard let p = profile else { return "" }
        let fmt = DateFormatter(); fmt.dateStyle = .medium
        let exp = p.expirationDate.map { fmt.string(from: $0) } ?? "—"
        let type: String
        switch p.type {
        case .development: type = "Development"
        case .adHoc: type = "Ad Hoc"
        case .appStore: type = "App Store"
        case .enterprise: type = "Enterprise"
        case .unknown: type = "Unknown"
        }
        return "\(type) · team \(p.teamIdentifier) · \(p.provisionedDeviceCount) devices · expires \(exp)"
    }

    enum IdentityStatus { case none, noMatch, matched, expired }
    var identityStatus: IdentityStatus {
        guard let p = profile else { return .none }
        if p.isExpired { return .expired }
        return matchedIdentities.isEmpty ? .noMatch : .matched
    }

    // MARK: Inputs

    func onAppear() { refreshIdentities(); refreshDevices() }

    func refreshDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let service = DeviceService()
            let brew = HomebrewService()
            let available = service.isAvailable
            let brewAvailable = brew.isBrewAvailable
            let version = available ? brew.installedVersion(ofTool: "ideviceinstaller") : nil
            let list = available ? ((try? service.listDevices()) ?? []) : []
            DispatchQueue.main.async {
                self.deviceToolsAvailable = available
                self.brewAvailable = brewAvailable
                self.toolVersion = version
                self.devices = list
                if self.selectedDeviceUDID == nil || !list.contains(where: { $0.udid == self.selectedDeviceUDID }) {
                    self.selectedDeviceUDID = list.first?.udid
                }
            }
        }
    }

    /// Checks Homebrew for updates to the device tools (on demand — needs network).
    func checkToolUpdates() {
        toolCheckBusy = true
        toolUpdateMessage = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outdated = (try? HomebrewService().outdatedFormulae()) ?? []
            DispatchQueue.main.async {
                self.toolUpdateAvailable = !outdated.isEmpty
                self.toolUpdateMessage = outdated.isEmpty
                    ? "Up to date"
                    : "Update available: \(outdated.joined(separator: ", "))"
                self.toolCheckBusy = false
            }
        }
    }

    func installDeviceTools() {
        runHomebrew(title: "Installing device tools") { try HomebrewService().install(progress: $0) }
    }
    func updateDeviceTools() {
        runHomebrew(title: "Updating device tools") { try HomebrewService().upgrade(progress: $0) }
    }

    // MARK: External tools panel

    @Published var showTools = false
    @Published var toolStatuses: [ToolStatus] = []
    @Published var toolsChecking = false
    @Published var toolBusy = false
    @Published var toolBusyTitle = ""
    @Published var toolLog: [String] = []
    private var outdatedFormulae: Set<String> = []

    private func toolVersion(_ tool: ExternalTool) -> String? {
        guard let arg = tool.versionArg, let path = DeviceService.findTool(tool.id) else { return nil }
        let r = try? ProcessRunner().run(path, [arg])
        return HomebrewService.parseVersion((r?.stdout ?? "") + "\n" + (r?.stderr ?? ""))
    }

    func refreshToolStatuses() {
        DispatchQueue.global(qos: .userInitiated).async {
            let statuses = ToolsInspector().statuses(
                findPath: { DeviceService.findTool($0) },
                version: { self.toolVersion($0) },
                outdatedFormulae: self.outdatedFormulae)
            DispatchQueue.main.async { self.toolStatuses = statuses }
        }
    }

    func checkAllToolUpdates() {
        guard HomebrewService().isBrewAvailable else { return }
        toolsChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outdated = Set((try? HomebrewService().outdatedFormulae(ToolCatalog.homebrewFormulae)) ?? [])
            DispatchQueue.main.async {
                self.outdatedFormulae = outdated
                self.toolsChecking = false
                self.refreshToolStatuses()
            }
        }
    }

    func installFormula(_ formula: String) {
        runToolAction(title: "Installing \(formula)…") { try HomebrewService().install([formula], progress: $0) }
    }
    func updateFormula(_ formula: String) {
        runToolAction(title: "Updating \(formula)…") { try HomebrewService().upgrade([formula], progress: $0) }
    }
    func updateAllOutdatedTools() {
        let formulae = toolStatuses.filter { $0.updateAvailable }.compactMap { $0.tool.formula }
        guard !formulae.isEmpty else { return }
        runToolAction(title: "Updating \(formulae.joined(separator: ", "))…") {
            try HomebrewService().upgrade(formulae, progress: $0)
        }
    }

    var brewAvailableForTools: Bool { HomebrewService().isBrewAvailable }

    // MARK: optool via GitHub releases

    @Published var optoolLatestTag: String?
    private var optoolAsset: GitHubReleaseService.Asset?

    func checkOptoolLatest() {
        toolBusy = true; toolBusyTitle = "Checking optool releases…"; toolLog = []
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let release = try GitHubReleaseService().fetchLatest(repo: "alexzielenski/optool")
                let asset = GitHubReleaseService.pickBinaryAsset(release, named: "optool")
                DispatchQueue.main.async {
                    self.optoolLatestTag = release.tag
                    self.optoolAsset = asset
                    self.toolLog.append("Latest optool release: \(release.tag)"
                        + (asset.map { " · \($0.name) (\($0.size) bytes)" } ?? ""))
                    self.toolBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.toolLog.append("❌ \(error.localizedDescription)"); self.toolBusy = false
                }
            }
        }
    }

    /// Downloads the latest optool binary to a user-chosen location. Never executes it.
    func downloadOptool(to destination: URL) {
        guard let asset = optoolAsset else { checkOptoolLatest(); return }
        toolBusy = true; toolBusyTitle = "Downloading optool \(optoolLatestTag ?? "")…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let service = GitHubReleaseService()
                let data = try service.download(asset.downloadURL)
                let binary = try service.extractBinary(named: "optool", assetName: asset.name, data: data)
                try binary.write(to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                DispatchQueue.main.async {
                    self.toolLog.append("✅ Saved optool (\(binary.count) bytes) to \(destination.path)")
                    self.toolLog.append("Note: optool is not used by AppSigner and was not executed.")
                    self.toolBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.toolLog.append("❌ \(error.localizedDescription)"); self.toolBusy = false
                }
            }
        }
    }

    private func runToolAction(title: String, work: @escaping ((@escaping (String) -> Void) throws -> Void)) {
        toolBusy = true; toolBusyTitle = title; toolLog = []
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work { line in DispatchQueue.main.async { if !line.isEmpty { self.toolLog.append(line) } } }
                DispatchQueue.main.async {
                    self.toolLog.append("✅ Done")
                    self.toolBusy = false
                    self.outdatedFormulae.removeAll()
                    self.refreshToolStatuses()
                    self.refreshDevices()
                }
            } catch {
                DispatchQueue.main.async {
                    self.toolLog.append("❌ \(error.localizedDescription)")
                    self.toolBusy = false
                }
            }
        }
    }

    private func runHomebrew(title: String, work: @escaping ((@escaping (String) -> Void) throws -> Void)) {
        steps = [ProcessStep(title: title, status: .active)]
        log = []; resultURL = nil; errorMessage = nil
        isRunning = true; showProcess = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work { line in DispatchQueue.main.async { if !line.isEmpty { self.log.append(line) } } }
                DispatchQueue.main.async {
                    self.completeLast()
                    self.log.append("✅ Done")
                    self.isRunning = false
                    self.toolUpdateAvailable = false
                    self.toolUpdateMessage = nil
                    self.refreshDevices()
                }
            } catch {
                DispatchQueue.main.async { self.finishFailure(error) }
            }
        }
    }

    func refreshIdentities() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = (try? KeychainService().listCodeSigningIdentities()) ?? []
            DispatchQueue.main.async {
                self.identities = ids
                self.recomputeMatches()
            }
        }
    }

    /// Routes any dropped/chosen files to the right slot by extension.
    func acceptFiles(_ urls: [URL]) {
        for url in urls { acceptFile(url) }
    }

    func acceptFile(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "ipa": setIPA(url)
        case "mobileprovision": setProfile(url)
        case "dylib": addDylib(url)
        case "deb": loadTweakPackage(url)
        case "png", "jpg", "jpeg", "heic": iconURL = url
        default: errorMessage = "Unsupported file: \(url.lastPathComponent) (need .ipa, .mobileprovision, .dylib, .deb or an image)"
        }
    }

    func addDylib(_ url: URL) {
        guard !dylibs.contains(where: { $0.lastPathComponent == url.lastPathComponent }) else { return }
        dylibs.append(url)
    }
    func removeDylib(_ url: URL) { dylibs.removeAll { $0 == url } }
    func clearIcon() { iconURL = nil }

    /// Extracts a .deb and adds its libraries to the injection list.
    func loadTweakPackage(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("deb-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                let contents = try DebPackage.extract(deb: url, to: dir)
                let tweak = LoadedTweak(info: contents.info, dylibs: contents.dylibs,
                                        bundles: contents.bundles,
                                        targetBundleIDs: contents.targetBundleIDs,
                                        requiresSubstrate: contents.requiresSubstrate,
                                        root: dir)
                DispatchQueue.main.async {
                    self.tweaks.append(tweak)
                    for dylib in contents.dylibs { self.addDylib(dylib) }
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async {
                    self.errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func removeTweak(_ tweak: LoadedTweak) {
        dylibs.removeAll { url in tweak.dylibs.contains(url) }
        tweaks.removeAll { $0.id == tweak.id }
        try? FileManager.default.removeItem(at: tweak.root)
    }

    func clearIPA() {
        ipaURL = nil; originalInfo = nil; report = nil; originalEntitlements = nil
        bundleID = ""; displayName = ""; shortVersion = ""; bundleVersion = ""
        clearContentsSelection()
    }
    func clearProfile() { profileURL = nil; profile = nil; matchedIdentities = []; selectedIdentitySHA1 = nil }

    func setIPA(_ url: URL) {
        ipaURL = url; resultURL = nil; errorMessage = nil
        report = nil
        originalEntitlements = nil
        clearContentsSelection()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try IPAPackage.readAppInfo(ipa: url)
                DispatchQueue.main.async {
                    self.originalInfo = info
                    self.bundleID = info.bundleID
                    self.displayName = info.displayName
                    self.shortVersion = info.shortVersion
                    self.bundleVersion = info.bundleVersion
                }
            } catch {
                DispatchQueue.main.async { self.errorMessage = "Failed to read IPA: \(error.localizedDescription)" }
            }
        }
    }

    func setProfile(_ url: URL) {
        profileURL = url; resultURL = nil; errorMessage = nil
        do {
            profile = try ProvisioningProfile.parse(data: Data(contentsOf: url))
            recomputeMatches()
        } catch {
            profile = nil
            errorMessage = "Failed to read profile: \(error.localizedDescription)"
        }
    }

    private func recomputeMatches() {
        guard let p = profile else { matchedIdentities = []; return }
        matchedIdentities = KeychainService.identities(identities, matchingCertificateSHA1s: p.developerCertificateSHA1s)
        if selectedIdentitySHA1 == nil || !matchedIdentities.contains(where: { $0.sha1 == selectedIdentitySHA1 }) {
            selectedIdentitySHA1 = matchedIdentities.first?.sha1
        }
    }

    private func currentEdits() -> InfoPlistEdits {
        guard let o = originalInfo else { return .init() }
        return InfoPlistEdits(
            bundleIdentifier: bundleID != o.bundleID ? bundleID : nil,
            shortVersion:     shortVersion != o.shortVersion ? shortVersion : nil,
            bundleVersion:    bundleVersion != o.bundleVersion ? bundleVersion : nil,
            displayName:      displayName != o.displayName ? displayName : nil
        )
    }

    // MARK: Signing + process screen

    func sign() {
        guard let ipaURL, let profileURL, let sha1 = selectedIdentitySHA1 else { return }
        steps = []; log = []; signCount = 0
        resultURL = nil; errorMessage = nil
        isRunning = true; showProcess = true

        let request = SigningRequest(ipa: ipaURL, profileURL: profileURL,
                                     identitySHA1: sha1, edits: currentEdits(),
                                     dylibs: dylibs, iconImage: iconURL,
                                     resourceBundles: resourceBundles,
                                     bundleEdits: bundleEdits, injectWeak: injectWeak,
                                     outputURL: nil)
        let shouldInstall = installAfterSign && deviceToolsAvailable
        let udid = selectedDeviceUDID
        let deviceName = devices.first { $0.udid == udid }?.name ?? "connected device"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try SigningPipeline().sign(request) { event in
                    DispatchQueue.main.async { self.apply(event) }
                }
                DispatchQueue.main.async {
                    self.completeLast()
                    self.resultURL = result.outputURL
                    self.log.append("✅ \(result.authority)")
                    self.log.append("   team \(result.teamIdentifier) · \(result.signedComponentCount) components")
                }

                if shouldInstall {
                    DispatchQueue.main.async {
                        self.steps.append(ProcessStep(title: "Installing on device", detail: deviceName, status: .active))
                    }
                    try DeviceService().install(ipa: result.outputURL, udid: udid) { line in
                        DispatchQueue.main.async { if !line.isEmpty { self.log.append("  \(line)") } }
                    }
                    DispatchQueue.main.async { self.completeLast(); self.log.append("📲 Installed on \(deviceName)") }
                }

                DispatchQueue.main.async { self.isRunning = false }
            } catch {
                DispatchQueue.main.async { self.finishFailure(error) }
            }
        }
    }

    private func apply(_ event: PipelineEvent) {
        log.append("• \(event.description)")
        switch event {
        case .signing(let name):
            signCount += 1
            if let i = steps.indices.last, steps[i].title == "Signing components" {
                steps[i].detail = "\(name)  ·  \(signCount) signed"
            } else {
                completeLast()
                steps.append(ProcessStep(title: "Signing components",
                                         detail: "\(name)  ·  \(signCount) signed", status: .active))
            }
        case .done:
            completeLast()
        default:
            completeLast()
            steps.append(ProcessStep(title: event.description, status: .active))
        }
    }

    private func completeLast() {
        if let i = steps.indices.last, steps[i].status == .active { steps[i].status = .done }
    }

    private func finishFailure(_ error: Error) {
        if let i = steps.indices.last { steps[i].status = .failed }
        errorMessage = error.localizedDescription
        log.append("❌ \(error.localizedDescription)")
        isRunning = false
    }
}
