import SwiftUI
import SigningKit

/// Lists the pre-flight findings with what each one means.
struct PreflightView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checklist").font(.title3).foregroundStyle(.tint)
                Text("Pre-flight checks").font(.headline)
                Spacer()
                if model.report == nil {
                    Button("Scan app") { model.inspectIPA() }.controlSize(.small)
                        .disabled(model.inspecting)
                }
            }
            if model.report == nil {
                Label("Scan the app to also check its binaries, libraries and extensions.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.findings.isEmpty {
                        Label("No issues found.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.callout)
                    }
                    ForEach(model.findings) { finding in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(finding.severity))
                                .foregroundStyle(color(finding.severity))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title).font(.callout.weight(.medium))
                                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 7).padding(.horizontal, 9)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
            }

            Divider()
            HStack {
                Text("Findings are advisory — signing is never blocked by this list.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private func icon(_ s: PreflightFinding.Severity) -> String {
        switch s {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    private func color(_ s: PreflightFinding.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
