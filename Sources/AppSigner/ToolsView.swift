import SwiftUI
import AppKit
import SigningKit

/// The external-tools panel: lists every tool AppSigner may use, its version, and
/// (for Homebrew-managed tools) install / update actions. System tools are shown for
/// reference; the legacy optool is shown as unused with no update channel.
struct ToolsView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("External tools", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Spacer()
                if model.toolsChecking { ProgressView().controlSize(.small) }
                Button("Check for updates") { model.checkAllToolUpdates() }
                    .controlSize(.small)
                    .disabled(!model.brewAvailableForTools || model.toolsChecking || model.toolBusy)
            }
            if !model.brewAvailableForTools {
                Label("Homebrew not found — install it from brew.sh to manage these tools.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                ForEach(model.toolStatuses) { status in
                    ToolRow(status: status)
                }
            }

            if model.toolBusy || !model.toolLog.isEmpty {
                Divider()
                if model.toolBusy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.toolBusyTitle).font(.caption) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.toolLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 90)
            }

            Spacer(minLength: 0)

            HStack {
                if model.toolStatuses.contains(where: { $0.updateAvailable }) {
                    Button("Update all") { model.updateAllOutdatedTools() }
                        .disabled(model.toolBusy)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.toolBusy)
            }
        }
        .padding(20)
        .frame(width: 500, height: 460)
        .onAppear { model.refreshToolStatuses() }
    }
}

private struct ToolRow: View {
    let status: ToolStatus
    @EnvironmentObject var model: SignerViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(status.tool.displayName).font(.subheadline.weight(.medium))
                    if let v = status.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                }
                Text(status.tool.purpose).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var icon: String {
        switch status.tool.manager {
        case .homebrew: return status.installed ? "shippingbox.fill" : "shippingbox"
        case .system:   return "applelogo"
        case .github:   return "arrow.down.circle"
        case .manual:   return "archivebox"
        }
    }
    private var color: Color {
        switch status.tool.manager {
        case .github, .manual: return .secondary
        case .homebrew, .system: return status.installed ? .green : .orange
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status.tool.manager {
        case .homebrew(let formula):
            if !status.installed {
                Button("Install") { model.installFormula(formula) }
                    .controlSize(.small).disabled(model.toolBusy || !model.brewAvailableForTools)
            } else if status.updateAvailable {
                Button("Update") { model.updateFormula(formula) }
                    .controlSize(.small).disabled(model.toolBusy)
                    .tint(.orange)
            } else {
                Text(status.installed ? "installed" : "").font(.caption).foregroundStyle(.secondary)
            }
        case .github:
            HStack(spacing: 6) {
                if let tag = model.optoolLatestTag {
                    Text("latest \(tag)").font(.caption).foregroundStyle(.secondary)
                    Button("Download…") { saveOptool() }.controlSize(.small).disabled(model.toolBusy)
                } else {
                    Button("Check latest") { model.checkOptoolLatest() }
                        .controlSize(.small).disabled(model.toolBusy)
                }
            }
        case .system:
            Text("macOS").font(.caption).foregroundStyle(.secondary)
        case .manual:
            Text("unused").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveOptool() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "optool"
        panel.title = "Save optool"
        panel.message = "Choose where to save the optool binary (from GitHub). It will not be executed."
        if panel.runModal() == .OK, let url = panel.url { model.downloadOptool(to: url) }
    }
}
