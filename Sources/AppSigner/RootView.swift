import SwiftUI
import AppKit

/// The app is one focused surface — signing — with tools reached from the top toolbar.
struct RootView: View {
    @EnvironmentObject var model: SignerViewModel
    @State private var showSavePreset = false
    @State private var presetName = ""

    var body: some View {
        SignPane()
            .frame(minWidth: 640, minHeight: 600)
            .background(WindowConfigurator(size: NSSize(width: 720, height: 720)))
            .toolbar { toolbar }
            .sheet(isPresented: $model.showProcess) { ProcessView() }
            .sheet(isPresented: $model.showPreflight) { PreflightView() }
            .sheet(isPresented: $model.showContents) { ContentsView().frame(width: 640, height: 580) }
            .sheet(isPresented: $model.showClassExplorer) { ClassExplorerView().frame(width: 620, height: 640) }
            .sheet(isPresented: $model.showPlistEditor) { PlistEditorView().frame(width: 620, height: 580) }
            .sheet(isPresented: $model.showDevTools) { DevToolsView().frame(width: 620, height: 540) }
            .sheet(isPresented: $model.showTools) { ToolsView().frame(width: 520, height: 480) }
            .alert("Save preset", isPresented: $showSavePreset) {
                TextField("Name", text: $presetName)
                Button("Save") { if !presetName.isEmpty { model.saveCurrentAsPreset(named: presetName) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stores the profile, identity, dylibs, icon and advanced options — not the bundle id, name or version.")
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Inspect the loaded app.
            toolButton("Contents", "shippingbox", enabled: model.ipaURL != nil) { model.showContents = true }
            toolButton("Binary Explorer", "curlybraces", enabled: model.ipaURL != nil) { model.showClassExplorer = true }
            toolButton("Info.plist", "doc.text", enabled: model.ipaURL != nil) { model.showPlistEditor = true }
            Divider()
            // Extend and configure.
            toolButton("Developer Tools", "hammer", badge: model.patches.count) { model.showDevTools = true }
            toolButton("External Tools", "wrench.and.screwdriver") { model.showTools = true }
            presetMenu
            Button { model.refreshIdentities() } label: { Label("Reload identities", systemImage: "arrow.clockwise") }
                .help("Reload Keychain identities")
        }
    }

    private func toolButton(_ title: String, _ icon: String, enabled: Bool = true,
                            badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(3).background(Circle().fill(.purple)).offset(x: 7, y: -6)
                    }
                }
        }
        .help(title)
        .disabled(!enabled)
    }

    private var presetMenu: some View {
        Menu {
            if model.presets.isEmpty {
                Text("No saved presets")
            } else {
                ForEach(model.presets) { preset in Button(preset.name) { model.applyPreset(preset) } }
                Divider()
                Menu("Delete") { ForEach(model.presets) { p in Button(p.name) { model.deletePreset(p) } } }
                Divider()
            }
            Button("Save current settings…") { presetName = ""; showSavePreset = true }
        } label: { Label("Presets", systemImage: "square.stack.3d.up") }
        .help("Presets")
    }
}
