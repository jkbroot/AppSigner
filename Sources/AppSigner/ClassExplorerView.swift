import SwiftUI
import SigningKit

/// Static analysis of the app's main binary: browse and search its Objective-C classes
/// and selectors, and compose method-return patches (applied via an injected hook dylib).
struct ClassExplorerView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.classes
    @State private var query = ""

    // Patch composer
    @State private var patchClass = ""
    @State private var patchSelector = ""
    @State private var valueKind = ValueKind.boolean
    @State private var boolValue = true
    @State private var textValue = ""

    private enum Tab: String, CaseIterable, Identifiable {
        case classes = "Classes", selectors = "Selectors"
        var id: String { rawValue }
    }
    private enum ValueKind: String, CaseIterable, Identifiable {
        case boolean = "Bool", integer = "Int", double = "Double", string = "String", null = "nil"
        var id: String { rawValue }
    }

    private var items: [String] {
        let all = tab == .classes ? (model.classDumpReport?.classNames ?? [])
                                  : (model.classDumpReport?.selectorNames ?? [])
        guard !query.isEmpty else { return all }
        return all.filter { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.classDumpLoading {
                VStack(spacing: 8) { ProgressView(); Text("Analysing the binary…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.classDumpReport == nil {
                Button("Analyse binary") { model.exploreBinary() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                browser
                Divider()
                composer
            }
            Divider()
            HStack {
                Text("Patches apply when you Sign, via an injected hook dylib. Zero-argument methods (getters).")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if model.classDumpReport == nil { model.exploreBinary() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Binary explorer").font(.headline)
                if let r = model.classDumpReport {
                    Text("\(r.classNames.count) classes · \(r.selectorNames.count) selectors")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var browser: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search — try premium, unlock, debug, enable…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
            }
            List(items, id: \.self) { name in
                HStack {
                    Text(name).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button(tab == .classes ? "Use as class" : "Use as selector") {
                        if tab == .classes { patchClass = name } else { patchSelector = name }
                    }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.tint)
                }
            }
            .listStyle(.plain).frame(minHeight: 180)
            .overlay { if items.isEmpty { Text("No matches").font(.caption).foregroundStyle(.secondary) } }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New patch").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                TextField("Class", text: $patchClass).textFieldStyle(.roundedBorder).controlSize(.small)
                TextField("Selector (getter)", text: $patchSelector).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("returns").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $valueKind) { ForEach(ValueKind.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 90)
                switch valueKind {
                case .boolean: Toggle(boolValue ? "YES" : "NO", isOn: $boolValue).controlSize(.small).frame(width: 70)
                case .null: Text("nil").font(.caption).foregroundStyle(.secondary)
                default:
                    TextField(valueKind == .string ? "text" : "number", text: $textValue)
                        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 120)
                }
                Spacer()
                Button("Add patch") { addPatch() }
                    .controlSize(.small)
                    .disabled(patchClass.isEmpty || patchSelector.isEmpty)
            }
            if !model.patches.isEmpty {
                ForEach(model.patches) { patch in
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").foregroundStyle(.purple).font(.caption)
                        Text(patch.summary).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button { model.removePatch(patch) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func addPatch() {
        let value: MethodPatch.ReturnValue
        switch valueKind {
        case .boolean: value = .boolean(boolValue)
        case .integer: value = .integer(Int(textValue) ?? 0)
        case .double: value = .double(Double(textValue) ?? 0)
        case .string: value = .string(textValue)
        case .null: value = .null
        }
        model.addPatch(MethodPatch(className: patchClass.trimmingCharacters(in: .whitespaces),
                                   selector: patchSelector.trimmingCharacters(in: .whitespaces),
                                   value: value))
        patchSelector = ""; textValue = ""
    }
}
