import SwiftUI
import AppKit
import CoreImage

/// Wireless install: runs a local HTTPS server that hosts the signed IPA, and shows a QR
/// code + step-by-step instructions for installing it on an iPhone over the network.
struct OTAView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wifi").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Install wirelessly").font(.headline)
                    Text("Serve the signed app over your local network — no cable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            if model.otaRunning { running } else { idle }

            Spacer(minLength: 0)
            HStack {
                if model.otaRunning {
                    Button("Stop server", role: .destructive) { model.stopOTA() }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Idle

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.otaError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("iOS installs over the air from an HTTPS link. AppSigner starts a local "
                 + "server with its own certificate — everything stays on your network.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.resultURL == nil {
                Label("Sign an app first, then come back here.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                model.startOTA()
            } label: {
                if model.otaStarting { ProgressView().controlSize(.small) }
                else { Label("Start server", systemImage: "play.fill") }
            }
            .controlSize(.large)
            .disabled(model.resultURL == nil || model.otaStarting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Running

    @ViewBuilder
    private var running: some View {
        VStack(spacing: 12) {
            if let qr = Self.qrImage(from: model.otaBaseURL, size: 190) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .frame(width: 190, height: 190)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text(model.otaBaseURL)
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "On the iPhone, join the same Wi-Fi as this Mac, then scan the QR code "
                        + "(or open the address above in Safari).")
                step(2, "Tap Install the certificate, then trust it in Settings → General → "
                        + "VPN & Device Management and Certificate Trust Settings.")
                step(3, "Tap Install the app and confirm. The device must be included in the profile.")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(.tint))
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: QR

    static func qrImage(from string: String, size: CGFloat) -> NSImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
