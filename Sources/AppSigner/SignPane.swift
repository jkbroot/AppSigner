import SwiftUI
import AppKit

/// The main signing surface: drop an app, choose identity, tweak metadata, sign.
struct SignPane: View {
    @EnvironmentObject var model: SignerViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeroDropZone { model.acceptFiles($0) }
                        .frame(minHeight: model.ipaURL == nil ? 190 : 120)
                        .animation(.easeInOut(duration: 0.2), value: model.ipaURL)

                    inputs
                    if model.isBatch { queue }
                    if model.ipaURL != nil { metadata }
                    additions
                    device
                }
                .padding(20)
            }
            actionBar
        }
    }

    // MARK: App / profile / identity

    private var inputs: some View {
        SectionCard {
            StatusRow(systemImage: "app.dashed", label: "App",
                      filename: model.ipaURL?.lastPathComponent,
                      detail: model.ipaURL != nil ? (model.removalSummary ?? model.appBundleName) : nil,
                      accessory: model.ipaURL == nil ? nil : AnyView(
                        HStack(spacing: 4) {
                            Button("Contents") { model.showContents = true }.controlSize(.small)
                            Button("Classes") { model.showClassExplorer = true }.controlSize(.small)
                        }),
                      onClear: { model.clearIPA() })
            Divider()
            StatusRow(systemImage: "doc.badge.gearshape", label: "Profile",
                      filename: model.profileURL?.lastPathComponent,
                      detail: model.profile != nil ? "\(model.profile?.name ?? "")  ·  \(model.profileSummary)" : nil,
                      onClear: { model.clearProfile() })
            Divider()
            identityRow
        }
    }

    @ViewBuilder
    private var identityRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").font(.system(size: 15)).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Signing identity").font(.caption).foregroundStyle(.secondary)
                switch model.identityStatus {
                case .matched:
                    Picker("", selection: Binding(
                        get: { model.selectedIdentitySHA1 ?? "" },
                        set: { model.selectedIdentitySHA1 = $0 })) {
                        ForEach(model.matchedIdentities, id: \.sha1) { Text($0.commonName).tag($0.sha1) }
                    }
                    .labelsHidden()
                case .none:
                    Text("Select a profile to match an identity").foregroundStyle(.secondary)
                case .noMatch:
                    Text("No matching Keychain identity — import the .p12").foregroundStyle(.red)
                case .expired:
                    Text("Provisioning profile has expired").foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    // MARK: Batch queue

    private var queue: some View {
        SectionCard("Batch", systemImage: "square.stack.3d.up.fill") {
            ForEach(model.batchQueue, id: \.self) { url in
                ChipRow(systemImage: "square.stack", title: url.lastPathComponent,
                        subtitle: nil, onRemove: { model.removeFromQueue(url) })
            }
            Text("Shared settings apply to every app. Bundle ID, name and version are left untouched.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Metadata

    private var metadata: some View {
        SectionCard("Metadata", systemImage: "pencil",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            if model.hasAdvancedPlistEdits {
                                Text("advanced edits").font(.caption2).foregroundStyle(.orange)
                            }
                            Button("Advanced…") { model.showPlistEditor = true }.controlSize(.small)
                        })) {
            EditRow("Bundle ID", $model.bundleID, placeholder: "com.example.app")
            EditRow("Name", $model.displayName, placeholder: "Display name")
            HStack(spacing: 12) {
                EditRow("Version", $model.shortVersion, placeholder: "1.0", labelWidth: 92)
                EditRow("Build", $model.bundleVersion, placeholder: "1", labelWidth: 48)
            }
        }
    }

    // MARK: Additions (dylibs, tweaks, frameworks, icon, patches)

    @ViewBuilder
    private var additions: some View {
        let hasAny = !model.dylibs.isEmpty || !model.tweaks.isEmpty || !model.allFrameworks.isEmpty
            || model.iconURL != nil || !model.patches.isEmpty
        if hasAny {
            SectionCard("Additions", systemImage: "plus.square.on.square") {
                if let icon = model.iconURL {
                    HStack(spacing: 10) {
                        Image(systemName: "photo").foregroundStyle(.secondary).frame(width: 20)
                        if let nsImage = NSImage(contentsOf: icon) {
                            Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text(icon.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.clearIcon() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.tweaks) { tweak in
                    ChipRow(systemImage: "shippingbox.fill",
                            title: "\(tweak.info.name) \(tweak.info.version)",
                            subtitle: "\(tweak.dylibs.count) dylib(s)"
                                + (tweak.frameworks.isEmpty ? "" : " · \(tweak.frameworks.count) framework(s)"),
                            onRemove: { model.removeTweak(tweak) })
                }
                ForEach(model.allFrameworks, id: \.self) { url in
                    ChipRow(systemImage: "cube.box.fill", title: url.lastPathComponent,
                            subtitle: model.extraFrameworks.contains(url) ? nil : "from tweak",
                            trailing: model.extraFrameworks.contains(url) ? nil : "bundled",
                            onRemove: model.extraFrameworks.contains(url) ? { model.removeFramework(url) } : nil)
                }
                ForEach(model.dylibs, id: \.self) { url in
                    ChipRow(systemImage: "puzzlepiece.extension.fill", title: url.lastPathComponent,
                            subtitle: nil, onRemove: { model.removeDylib(url) })
                }
                ForEach(model.patches) { patch in
                    ChipRow(systemImage: "wand.and.stars", title: patch.summary,
                            subtitle: nil, tint: .purple, onRemove: { model.removePatch(patch) })
                }
            }
        }
    }

    // MARK: Device install

    private var device: some View {
        SectionCard("Install", systemImage: "iphone",
                    accessory: AnyView(
                        Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Refresh devices"))) {
            Toggle("Install on device after signing", isOn: $model.installAfterSign)
                .disabled(!model.deviceToolsAvailable)
            if !model.deviceToolsAvailable {
                HStack(spacing: 6) {
                    Text("Device tools not installed.").font(.caption).foregroundStyle(.orange)
                    Button("Set up in External Tools") { model.showTools = true }.controlSize(.small)
                }
            } else if model.installAfterSign {
                if model.devices.isEmpty {
                    Text("No device connected — plug in an iPhone and tap Refresh")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Device", selection: Binding(
                        get: { model.selectedDeviceUDID ?? "" },
                        set: { model.selectedDeviceUDID = $0 })) {
                        ForEach(model.devices) { Text($0.name).tag($0.udid) }
                    }
                }
            }
        }
    }

    // MARK: Bottom action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if model.canRunPreflight { preflightChip }
                if let out = model.resultURL, !model.showProcess {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    } label: {
                        Label(out.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
                Spacer()
                Button(action: { model.sign() }) {
                    Label(model.isBatch ? "Sign \(model.allIPAs.count) apps" : "Sign", systemImage: "signature")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.isReadyToSign)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var preflightChip: some View {
        Button { model.showPreflight = true } label: {
            HStack(spacing: 6) {
                Image(systemName: model.errorCount > 0 ? "xmark.octagon.fill"
                      : (model.warningCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                    .foregroundStyle(model.errorCount > 0 ? .red : (model.warningCount > 0 ? .orange : .green))
                Text(preflightSummary).font(.callout)
            }
        }
        .buttonStyle(.borderless)
    }

    private var preflightSummary: String {
        if model.errorCount > 0 || model.warningCount > 0 {
            var parts: [String] = []
            if model.errorCount > 0 { parts.append("\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")") }
            if model.warningCount > 0 { parts.append("\(model.warningCount) warning\(model.warningCount == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
        return model.report == nil ? "Ready to sign" : "No issues"
    }
}
