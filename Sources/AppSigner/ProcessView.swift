import SwiftUI
import AppKit

/// The process screen shown while signing: a live checklist of pipeline steps,
/// then the result (success + output, or error).
struct ProcessView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    private var titleText: String {
        if model.isRunning { return "Signing…" }
        if model.errorMessage != nil { return "Failed" }
        if model.resultURL != nil { return "Done" }
        return "Signing"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                statusGlyph
                Text(titleText).font(.headline)
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        stepIcon(step.status).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.subheadline)
                                .foregroundStyle(step.status == .pending ? .secondary : .primary)
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                if model.steps.isEmpty {
                    Text("Preparing…").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(20)
        .frame(width: 440, height: 430)
    }

    private var statusGlyph: some View {
        Group {
            if model.isRunning {
                Image(systemName: "gearshape.2.fill").foregroundStyle(.tint)
            } else if model.errorMessage != nil {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
        .font(.title3)
    }

    @ViewBuilder
    private func stepIcon(_ status: ProcessStep.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .active:  ProgressView().controlSize(.small)
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = model.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let out = model.resultURL {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.green)
                Text(out.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
        }

        DisclosureGroup(isExpanded: $showLog) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 90)
        } label: {
            Text("Details").font(.caption).foregroundStyle(.secondary)
        }

        HStack {
            Spacer()
            if let out = model.resultURL {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            Button(model.isRunning ? "Working…" : "Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)
        }
    }
}
