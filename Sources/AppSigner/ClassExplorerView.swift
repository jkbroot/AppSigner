import SwiftUI
import SigningKit

/// Static analysis of any binary in the bundle: browse and search its Objective-C classes,
/// selectors and string literals, and compose method-return patches (applied via an injected
/// hook dylib) or in-place string patches (rewritten in the binary before signing).
struct ClassExplorerView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.classes
    @State private var query = ""

    // Method-patch composer
    @State private var patchClass = ""
    @State private var patchSelector = ""
    @State private var valueKind = ValueKind.boolean
    @State private var boolValue = true
    @State private var textValue = ""

    // String-patch composer
    @State private var stringOriginal = ""
    @State private var stringReplacement = ""

    private enum Tab: String, CaseIterable, Identifiable {
        case classes = "Classes", selectors = "Selectors", strings = "Strings"
        var id: String { rawValue }
    }
    private enum ValueKind: String, CaseIterable, Identifiable {
        case boolean = "Bool", integer = "Int", double = "Double", string = "String", null = "nil"
        var id: String { rawValue }
    }

    private var items: [String] {
        let all: [String]
        switch tab {
        case .classes: all = model.classDumpReport?.classNames ?? []
        case .selectors: all = model.classDumpReport?.selectorNames ?? []
        case .strings: all = model.binaryStrings
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.explorerLoading {
                VStack(spacing: 8) { ProgressView(); Text("Analysing the binary…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.explorerBinaries.isEmpty {
                Button("Analyse binary") { model.exploreBinary() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                binaryPicker
                browser
                Divider()
                if tab == .strings { stringComposer } else { composer }
            }
            Divider()
            HStack {
                Text(tab == .strings
                     ? "String patches rewrite the binary in place before signing — the new text must fit the original."
                     : "Method patches apply when you Sign, via an injected hook dylib. Zero-argument getters work best.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if model.explorerBinaries.isEmpty { model.exploreBinary() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Binary explorer").font(.headline)
                if let r = model.classDumpReport {
                    Text("\(r.classNames.count) classes · \(r.selectorNames.count) selectors · \(model.binaryStrings.count) strings")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// Choose which Mach-O in the bundle to inspect (main app, extension, framework, dylib).
    private var binaryPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.selectedBinaryPath ?? "" },
                set: { model.selectBinary($0) })) {
                ForEach(model.explorerBinaries) { binary in
                    Text("\(label(for: binary.role))  \((binary.id as NSString).lastPathComponent)").tag(binary.id)
                }
            }
            .labelsHidden()
        }
    }

    private var browser: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(searchPrompt, text: $query).textFieldStyle(.roundedBorder)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
            }
            List(items, id: \.self) { name in
                HStack {
                    Text(name).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(useLabel) {
                        switch tab {
                        case .classes: patchClass = name
                        case .selectors: patchSelector = name
                        case .strings: stringOriginal = name; stringReplacement = ""
                        }
                    }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.tint)
                }
            }
            .listStyle(.plain).frame(minHeight: 180)
            .overlay { if items.isEmpty { Text("No matches").font(.caption).foregroundStyle(.secondary) } }
        }
    }

    private var searchPrompt: String {
        switch tab {
        case .classes, .selectors: return "Search — try premium, unlock, debug, enable…"
        case .strings: return "Search strings — try http, key, enabled, /v1…"
        }
    }
    private var useLabel: String {
        switch tab {
        case .classes: return "Use as class"
        case .selectors: return "Use as selector"
        case .strings: return "Patch…"
        }
    }

    // MARK: Method-patch composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New method patch").font(.subheadline.weight(.semibold))
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
            patchList(model.patches.map(\.summary), icon: "wand.and.stars", tint: .purple) { i in
                model.removePatch(model.patches[i])
            }
        }
    }

    // MARK: String-patch composer

    private var stringComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New string patch").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Text(stringOriginal.isEmpty ? "Pick a string above" : stringOriginal)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(stringOriginal.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 190, alignment: .leading)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                TextField("replacement", text: $stringReplacement)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                Text("\(stringReplacement.utf8.count)/\(stringOriginal.utf8.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(overBudget ? .red : .secondary)
                Button("Add") { addStringPatch() }
                    .controlSize(.small)
                    .disabled(stringOriginal.isEmpty || stringReplacement.isEmpty || overBudget)
            }
            let mine = model.stringPatches.filter { $0.binaryPath == model.selectedBinaryPath }
            patchList(mine.map(\.summary), icon: "text.badge.xmark", tint: .orange) { i in
                model.removeStringPatch(mine[i])
            }
        }
    }

    private var overBudget: Bool { stringReplacement.utf8.count > stringOriginal.utf8.count }

    // MARK: Shared

    @ViewBuilder
    private func patchList(_ summaries: [String], icon: String, tint: Color,
                           remove: @escaping (Int) -> Void) -> some View {
        if !summaries.isEmpty {
            ForEach(Array(summaries.enumerated()), id: \.offset) { index, summary in
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(tint).font(.caption)
                    Text(summary).font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { remove(index) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(for role: BinaryReport.Role) -> String {
        switch role {
        case .mainExecutable: return "App"
        case .appExtension: return "Extension"
        case .framework: return "Framework"
        case .dylib: return "Dylib"
        case .watchExecutable: return "Watch"
        case .other: return "Binary"
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

    private func addStringPatch() {
        guard let binaryPath = model.selectedBinaryPath, !overBudget else { return }
        model.addStringPatch(StringPatch(binaryPath: binaryPath,
                                         original: stringOriginal, replacement: stringReplacement))
        stringReplacement = ""
    }
}
