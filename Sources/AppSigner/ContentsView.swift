import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SigningKit

/// The IPA explorer: shows every dylib reference and every removable bundle entry,
/// and lets the user pick what to strip out during signing.
struct ContentsView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss

    /// Kinds that are always worth listing; `.other` entries are trimmed to the largest few.
    private let alwaysShown: Set<BundleItem.Kind> = [
        .appExtension, .watchApp, .appClip, .framework, .dylib,
        .resourceBundle, .localization, .assetCatalog, .fairplayLeftover,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if model.inspecting {
                loading
            } else if let report = model.report {
                content(report)
            } else {
                Button("Scan app contents") { model.inspectIPA() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if model.report == nil { model.inspectIPA() } }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.report?.appName ?? model.ipaURL?.lastPathComponent ?? "App contents")
                    .font(.headline)
                if let r = model.report {
                    Text("\(r.bundleID) · \(r.version) · \(byteText(r.totalSize))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.report != nil {
                Button("Rescan") { model.report = nil; model.inspectIPA() }
                    .controlSize(.small)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Unpacking and scanning…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ report: BundleReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if report.isEncrypted {
                    Label("This app's main binary is FairPlay-encrypted — re-signing it will not produce a runnable app.",
                          systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                ForEach(report.binaries.filter { hasInteresting($0) }) { binary in
                    dylibSection(binary)
                }

                let items = visibleItems(report)
                if !items.isEmpty {
                    Text("Bundle contents").font(.subheadline.weight(.semibold))
                    ForEach(items) { item in itemRow(item, report: report) }
                }
            }
        }
    }

    private func dylibSection(_ binary: BinaryReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(binary.id).font(.subheadline.weight(.semibold))
                Text(binary.architectures.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(binary.dylibs.filter { $0.kind != .system }) { dylib in
                dylibRow(binary: binary, dylib: dylib)
            }
        }
    }

    private func dylibRow(binary: BinaryReport, dylib: ResolvedDylib) -> some View {
        let key = SignerViewModel.dylibKey(binary.id, dylib.path)
        let removed = model.removedDylibKeys.contains(key)
        let referrers = (model.report?.referrers[dylib.resolvedRelativePath ?? ""] ?? [])
            .filter { $0 != binary.id }
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { removed },
                set: { on in
                    if on { model.removedDylibKeys.insert(key) } else { model.removedDylibKeys.remove(key) }
                }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text((dylib.path as NSString).lastPathComponent).font(.callout)
                    badge(dylib.isWeak ? "weak" : "strong", dylib.isWeak ? .green : .secondary)
                    badge(dylib.kind.rawValue, color(for: dylib.kind))
                }
                Text(dylib.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !referrers.isEmpty {
                    Text("also used by: \(referrers.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if dylib.kind == .jailbreak, !removed,
               let target = MachOFile.suggestedRPath(for: dylib.path) {
                Button(model.rewrittenDylibKeys.contains(key) ? "Will fix" : "Fix path") {
                    if model.rewrittenDylibKeys.contains(key) { model.rewrittenDylibKeys.remove(key) }
                    else { model.rewrittenDylibKeys.insert(key) }
                }
                .controlSize(.small)
                .tint(model.rewrittenDylibKeys.contains(key) ? .green : .orange)
                .help("Re-point at \(target) so it loads from inside the app")
            }
            if !dylib.isWeak && !removed {
                Button("Make weak") {
                    let k = SignerViewModel.dylibKey(binary.id, dylib.path)
                    if model.weakenedDylibKeys.contains(k) { model.weakenedDylibKeys.remove(k) }
                    else { model.weakenedDylibKeys.insert(k) }
                }
                .controlSize(.small)
                .tint(model.weakenedDylibKeys.contains(key) ? .green : nil)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func itemRow(_ item: BundleItem, report: BundleReport) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { model.removedItems.contains(item.id) },
                set: { on in
                    if on { model.removedItems.insert(item.id) } else { model.removedItems.remove(item.id) }
                }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout)
                    badge(item.kind.rawValue, .secondary)
                }
                if let warning = item.warning {
                    Text(warning).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if item.kind == .appExtension {
                if let assigned = model.extensionProfiles[item.id] {
                    Button {
                        model.clearExtensionProfile(item.id)
                    } label: {
                        Label(assigned.deletingPathExtension().lastPathComponent,
                              systemImage: "checkmark.seal.fill")
                    }
                    .controlSize(.small).tint(.green)
                    .help("Remove this extension's profile")
                } else {
                    Button("Profile…") { assignProfile(to: item.id) }
                        .controlSize(.small)
                        .help("Give this extension its own provisioning profile")
                }
            }
            Text(byteText(item.sizeBytes)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.removalSummary ?? "Nothing selected — the app is signed unchanged.")
                    .font(.caption).foregroundStyle(model.removalSummary == nil ? .secondary : .primary)
                Toggle("Inject new dylibs as weak references", isOn: $model.injectWeak)
                    .font(.caption).controlSize(.small)
            }
            Spacer()
            if model.removalSummary != nil {
                Button("Clear") { model.clearContentsSelection() }.controlSize(.small)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    private func hasInteresting(_ binary: BinaryReport) -> Bool {
        binary.dylibs.contains { $0.kind != .system }
    }

    /// All meaningful entries plus the ten largest miscellaneous files.
    private func visibleItems(_ report: BundleReport) -> [BundleItem] {
        let removable = report.items.filter { !$0.isProtected }
        let meaningful = removable.filter { alwaysShown.contains($0.kind) }
        let others = removable.filter { $0.kind == .other }.prefix(10)
        return (meaningful + others).sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    private func color(for kind: ResolvedDylib.Kind) -> Color {
        switch kind {
        case .bundled: return .blue
        case .missing: return .red
        case .jailbreak: return .purple
        case .system: return .secondary
        }
    }

    private func assignProfile(to appexPath: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileprovision") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the provisioning profile for this app extension"
        if panel.runModal() == .OK, let url = panel.url {
            model.assignExtensionProfile(url, to: appexPath)
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
