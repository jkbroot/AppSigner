import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - File picking

enum FilePicker {
    /// Opens a panel accepting every input type AppSigner routes automatically.
    static func choose(onPick: @escaping ([URL]) -> Void) {
        let types = ["ipa", "mobileprovision", "dylib", "deb", "framework", "png", "jpg", "jpeg", "heic"]
            .compactMap { UTType(filenameExtension: $0) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.isEmpty ? [.data] : types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true      // .framework is a directory
        panel.prompt = "Add"
        panel.message = "Choose an .ipa, .mobileprovision, .dylib, .deb, .framework or an icon"
        if panel.runModal() == .OK { onPick(panel.urls) }
    }
}

// MARK: - Hero drop zone

/// The signature moment: a large, tactile target that glows when a file is dragged over it.
struct HeroDropZone: View {
    let onFiles: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        Button { FilePicker.choose(onPick: onFiles) } label: {
            VStack(spacing: 10) {
                Image(systemName: "signature")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: targeted)
                Text("Drop an app to sign")
                    .font(.title3.weight(.semibold))
                Text(".ipa · .mobileprovision · .dylib · .deb · .framework · icon")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Files are sorted automatically")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(targeted ? Color.accentColor : Color(nsColor: .separatorColor),
                                      style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: [7, 5]))
                }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted.animation(.easeOut(duration: 0.15))) { providers in
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

// MARK: - Grouped section card

/// A titled, material-backed group — the grouped-settings look, without forcing every
/// custom row through `Form`'s `LabeledContent`.
struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil,
         accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage
        self.accessory = accessory; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || accessory != nil {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                    if let title {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let accessory { accessory }
                }
            }
            VStack(spacing: 8) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
                }
        }
    }
}

// MARK: - Rows

/// A status line: icon + label + filename (or "Not selected") + optional trailing controls.
struct StatusRow: View {
    let systemImage: String
    let label: String
    let filename: String?
    let detail: String?
    var accessory: AnyView?
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15)).foregroundStyle(filename == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(filename ?? "Not selected")
                    .font(.body)
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
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
            }
        }
    }
}

/// A compact editable field row (label + text field).
struct EditRow: View {
    let label: String
    let text: Binding<String>
    let placeholder: String
    var labelWidth: CGFloat = 92
    init(_ label: String, _ text: Binding<String>, placeholder: String, labelWidth: CGFloat = 92) {
        self.label = label; self.text = text; self.placeholder = placeholder; self.labelWidth = labelWidth
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

/// A small removable chip row used for lists of added dylibs/tweaks/frameworks/patches.
struct ChipRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var tint: Color = .secondary
    var trailing: String?
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            if let onRemove {
                Button { onRemove() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
            }
        }
    }
}

// MARK: - Window configuration

/// Sets a sensible initial window size and disables stale frame restoration.
struct WindowConfigurator: NSViewRepresentable {
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
