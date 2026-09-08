import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SigningKit

struct ContentView: View {
    @EnvironmentObject var model: SignerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            UnifiedDropZone { model.acceptFiles($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            selectionRows
            if model.isBatch { queueSection }
            if model.iconURL != nil { iconRow }
            if !model.tweaks.isEmpty { tweaksSection }
            if !model.allFrameworks.isEmpty { frameworksSection }
            if !model.dylibs.isEmpty { dylibsSection }
            identityRow
            if model.ipaURL != nil { metadataRows }
            deviceRow
            if model.canRunPreflight { preflightRow }
            signBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowConfigurator(size: NSSize(width: 560, height: 600)))
        .sheet(isPresented: $model.showProcess) { ProcessView() }
        .sheet(isPresented: $model.showTools) { ToolsView() }
        .sheet(isPresented: $model.showContents) { ContentsView() }
        .sheet(isPresented: $model.showPreflight) { PreflightView() }
        .sheet(isPresented: $model.showPlistEditor) { PlistEditorView() }
        .alert("Save preset", isPresented: $showSavePreset) {
            TextField("Name", text: $presetName)
            Button("Save") { if !presetName.isEmpty { model.saveCurrentAsPreset(named: presetName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stores the profile, identity, dylibs, icon and advanced options — not the bundle id, name or version.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "signature")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            Text("AppSigner").font(.system(size: 16, weight: .bold))
            Text("Re-sign iOS apps").font(.caption).foregroundStyle(.secondary)
            Spacer()
            presetMenu
            Button { model.showTools = true } label: { Image(systemName: "wrench.and.screwdriver") }
                .buttonStyle(.borderless)
                .help("External tools")
            Button { model.refreshIdentities() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload Keychain identities")
        }
    }

    private var presetMenu: some View {
        Menu {
            if model.presets.isEmpty {
                Text("No saved presets")
            } else {
                ForEach(model.presets) { preset in
                    Button(preset.name) { model.applyPreset(preset) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
                Divider()
            }
            Button("Save current settings…") { presetName = ""; showSavePreset = true }
        } label: {
            Image(systemName: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton).frame(width: 26)
        .help("Presets")
    }

    // MARK: Selection status rows

    private var selectionRows: some View {
        VStack(spacing: 6) {
            StatusRow(systemImage: "app.dashed", label: "App",
                      filename: model.ipaURL?.lastPathComponent,
                      detail: model.ipaURL != nil ? (model.removalSummary ?? model.appBundleName) : nil,
                      accessory: model.ipaURL == nil ? nil : AnyView(
                        Button("Contents") { model.showContents = true }
                            .controlSize(.small)),
                      onClear: { model.clearIPA() })
            StatusRow(systemImage: "doc.badge.gearshape", label: "Profile",
                      filename: model.profileURL?.lastPathComponent,
                      detail: model.profile != nil ? "\(model.profile?.name ?? "")  ·  \(model.profileSummary)" : nil,
                      onClear: { model.clearProfile() })
        }
    }

    // MARK: Batch queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.batchQueue, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: "square.stack").foregroundStyle(.secondary).frame(width: 20)
                    Text("Queued").font(.subheadline).frame(width: 64, alignment: .leading)
                    Text(url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.removeFromQueue(url) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Text("Batch: shared settings apply to every app. Bundle ID, name and version are left untouched.")
                .font(.caption2).foregroundStyle(.secondary).padding(.leading, 30)
        }
    }

    // MARK: Icon

    @ViewBuilder
    private var iconRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary).frame(width: 20)
            Text("Icon").font(.subheadline).frame(width: 64, alignment: .leading)
            if let url = model.iconURL, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { model.clearIcon() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: Tweak packages

    private var tweaksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.tweaks) { tweak in
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.secondary).frame(width: 20)
                    Text("Tweak").font(.subheadline).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(tweak.info.name) \(tweak.info.version)").font(.subheadline)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(tweak.dylibs.count) dylib(s)"
                             + (tweak.bundles.isEmpty ? "" : " · \(tweak.bundles.count) bundle(s)")
                             + (tweak.targetBundleIDs.isEmpty ? "" : " · targets \(tweak.targetBundleIDs.joined(separator: ", "))"))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { model.removeTweak(tweak) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    // MARK: Frameworks

    private var frameworksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.allFrameworks, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: "cube.box.fill").foregroundStyle(.secondary).frame(width: 20)
                    Text("Framework").font(.subheadline).frame(width: 74, alignment: .leading)
                    Text(url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if model.extraFrameworks.contains(url) {
                        Button { model.removeFramework(url) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                    } else {
                        Text("from tweak").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    // MARK: Dylibs

    private var dylibsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.dylibs, id: \.self) { url in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary).frame(width: 20)
                    Text("Dylib").font(.subheadline).frame(width: 64, alignment: .leading)
                    Text(url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.removeDylib(url) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key").foregroundStyle(.secondary).frame(width: 20)
            Text("Identity").font(.subheadline).frame(width: 92, alignment: .leading)
            switch model.identityStatus {
            case .matched:
                Picker("", selection: Binding(
                    get: { model.selectedIdentitySHA1 ?? "" },
                    set: { model.selectedIdentitySHA1 = $0 })) {
                    ForEach(model.matchedIdentities, id: \.sha1) { Text($0.commonName).tag($0.sha1) }
                }
                .labelsHidden()
            case .none:
                Text("Select a profile to match an identity").font(.subheadline).foregroundStyle(.secondary)
            case .noMatch:
                Text("No matching Keychain identity — import the .p12")
                    .font(.subheadline).foregroundStyle(.red)
            case .expired:
                Text("Provisioning profile expired").font(.subheadline).foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // MARK: Metadata

    private var metadataRows: some View {
        VStack(spacing: 6) {
            EditRow("Bundle ID", $model.bundleID, placeholder: "com.example.app")
            EditRow("Name", $model.displayName, placeholder: "Display name")
            HStack(spacing: 10) {
                EditRow("Version", $model.shortVersion, placeholder: "1.0", labelWidth: 92)
                EditRow("Build", $model.bundleVersion, placeholder: "1", labelWidth: 48)
            }
            HStack(spacing: 8) {
                Spacer()
                if model.hasAdvancedPlistEdits {
                    Text("advanced changes pending").font(.caption2).foregroundStyle(.orange)
                }
                Button("Advanced…") { model.showPlistEditor = true }.controlSize(.small)
            }
        }
    }

    // MARK: Device install

    private var deviceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").foregroundStyle(.secondary).frame(width: 20)
                Toggle("Install on device after signing", isOn: $model.installAfterSign)
                    .disabled(!model.deviceToolsAvailable)
                Spacer()
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh devices")
            }

            Group {
                if !model.deviceToolsAvailable {
                    toolsMissing
                } else {
                    toolsInstalled
                    if model.installAfterSign { devicePickerOrHint }
                }
            }
            .padding(.leading, 30)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var toolsMissing: some View {
        HStack(spacing: 8) {
            Text("Device tools (ideviceinstaller) not installed.")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            if model.brewAvailable {
                Button("Install with Homebrew") { model.installDeviceTools() }
                    .controlSize(.small)
            } else {
                Button("Get Homebrew") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var toolsInstalled: some View {
        HStack(spacing: 8) {
            Label(model.toolVersion.map { "ideviceinstaller \($0)" } ?? "ideviceinstaller ready",
                  systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
            if let msg = model.toolUpdateMessage {
                Text("· \(msg)").font(.caption)
                    .foregroundStyle(model.toolUpdateAvailable ? .orange : .secondary)
            }
            Spacer()
            if model.toolCheckBusy {
                ProgressView().controlSize(.small)
            } else if model.toolUpdateAvailable {
                Button("Update") { model.updateDeviceTools() }.controlSize(.small)
            } else {
                Button("Check updates") { model.checkToolUpdates() }.controlSize(.small)
            }
        }
        .disabled(!model.brewAvailable)
    }

    @ViewBuilder
    private var devicePickerOrHint: some View {
        if model.devices.isEmpty {
            Text("No device connected — plug in an iPhone and tap Refresh")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("Device", selection: Binding(
                get: { model.selectedDeviceUDID ?? "" },
                set: { model.selectedDeviceUDID = $0 })) {
                ForEach(model.devices) { Text($0.name).tag($0.udid) }
            }
            .labelsHidden()
        }
    }

    // MARK: Pre-flight

    private var preflightRow: some View {
        HStack(spacing: 10) {
            Image(systemName: model.errorCount > 0 ? "xmark.octagon.fill"
                  : (model.warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                .foregroundStyle(model.errorCount > 0 ? .red
                                 : (model.warningCount > 0 ? .orange : .green))
                .frame(width: 20)
            Text(preflightSummary).font(.subheadline)
            Spacer()
            Button("Review") { model.showPreflight = true }.controlSize(.small)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var preflightSummary: String {
        if model.errorCount > 0 || model.warningCount > 0 {
            var parts: [String] = []
            if model.errorCount > 0 { parts.append("\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")") }
            if model.warningCount > 0 { parts.append("\(model.warningCount) warning\(model.warningCount == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
        return model.report == nil ? "Basic checks passed — scan for a full check" : "No issues found"
    }

    // MARK: Sign bar

    private var signBar: some View {
        VStack(spacing: 8) {
            Button(action: { model.sign() }) {
                Label(model.isBatch ? "Sign \(model.allIPAs.count) apps" : "Sign",
                      systemImage: "signature").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.isReadyToSign)

            if let out = model.resultURL, !model.showProcess {
                HStack {
                    Label(out.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    // MARK: File picker (accepts either type, multiple)

    fileprivate static func pickFiles(onPick: @escaping ([URL]) -> Void) {
        let types = ["ipa", "mobileprovision", "dylib", "deb", "framework", "png", "jpg", "jpeg", "heic"]
            .compactMap { UTType(filenameExtension: $0) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.isEmpty ? [.data] : types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true      // .framework is a directory
        panel.prompt = "Add"
        panel.message = "Choose an .ipa, .mobileprovision, .dylib, .deb and/or an icon image"
        if panel.runModal() == .OK { onPick(panel.urls) }
    }
}

// MARK: - Compact components

/// One smart drop area that receives both .ipa and .mobileprovision and routes by type.
private struct UnifiedDropZone: View {
    let onFiles: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        Button { ContentView.pickFiles(onPick: onFiles) } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                Text("Drag .ipa · .mobileprovision · .dylib · .deb · .framework · icon here")
                    .font(.subheadline).foregroundStyle(.primary)
                Text("or click to choose — files are sorted automatically")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(
                targeted ? Color.accentColor : Color(nsColor: .separatorColor),
                style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6]))
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            var collected: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !collected.isEmpty { onFiles(collected) } }
            return true
        }
    }
}

/// A simple status line: icon + label + filename (or "Not selected") + optional clear.
private struct StatusRow: View {
    let systemImage: String
    let label: String
    let filename: String?
    let detail: String?
    var accessory: AnyView? = nil
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 20)
            Text(label).font(.subheadline).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(filename ?? "Not selected")
                    .font(.subheadline)
                    .foregroundStyle(filename == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let accessory { accessory }
            if filename != nil {
                Button { onClear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove")
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// A compact label + text field editing row.
private struct EditRow: View {
    let label: String
    let text: Binding<String>
    let placeholder: String
    var labelWidth: CGFloat = 92
    init(_ label: String, _ text: Binding<String>, placeholder: String, labelWidth: CGFloat = 92) {
        self.label = label; self.text = text; self.placeholder = placeholder; self.labelWidth = labelWidth
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }
}

/// Sets a deterministic initial window size and disables frame restoration.
private struct WindowConfigurator: NSViewRepresentable {
    let size: NSSize
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isRestorable = false
            window.setFrameAutosaveName("")
            window.setContentSize(size)
            window.center()
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
