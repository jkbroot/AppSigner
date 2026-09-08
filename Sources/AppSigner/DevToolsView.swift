import SwiftUI
import AppKit
import SigningKit

/// Developer tools that can be injected into the app being signed.
/// Each one is built from its own source on this machine — nothing is shipped or downloaded.
struct DevToolsView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hammer").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Developer tools").font(.headline)
                    Text("Built from source on this Mac — never shipped or downloaded as binaries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.developerTools) { tool in toolCard(tool) }
                }
            }

            if model.devToolBusy || !model.devToolLog.isEmpty {
                Divider()
                if model.devToolBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.devToolTitle).font(.caption)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.devToolLog.suffix(200).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 90)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.devToolBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshDeveloperTools() }
    }

    private func toolCard(_ tool: DeveloperTool) -> some View {
        let ready = model.isToolReady(tool)
        let added = model.addedToolIDs.contains(tool.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tool.name).font(.subheadline.weight(.semibold))
                Text(tool.license).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                if ready {
                    Label("built", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                Link(destination: URL(string: tool.repository)!) {
                    Image(systemName: "link").font(.caption)
                }.help(tool.repository)
            }

            Text(tool.summary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let hint = tool.triggerHint {
                Label(hint, systemImage: "hand.tap").font(.caption2).foregroundStyle(.blue)
            }

            HStack(spacing: 8) {
                Text(tool.artifacts.map(\.fileName).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !ready {
                    Button("Locate…") { locate(tool) }.controlSize(.small).disabled(model.devToolBusy)
                    Button("Build") { model.buildTool(tool) }
                        .controlSize(.small).disabled(model.devToolBusy)
                } else if added {
                    Button("Remove") { model.removeTool(tool) }.controlSize(.small).tint(.orange)
                } else {
                    Button("Add to signing") { model.addTool(tool) }
                        .controlSize(.small).tint(.green)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func locate(_ tool: DeveloperTool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing \(tool.artifacts.map(\.fileName).joined(separator: " and "))"
        if panel.runModal() == .OK, let url = panel.url { model.importTool(tool, from: url) }
    }
}
