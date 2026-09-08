import SwiftUI
import SigningKit

/// The advanced `Info.plist` editor: curated compatibility options plus a raw key editor.
struct PlistEditorView: View {
    @EnvironmentObject var model: SignerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newKey = ""
    @State private var newValue = ""
    @State private var newType: ValueType = .string

    private enum ValueType: String, CaseIterable, Identifiable {
        case string = "Text", bool = "Yes/No", integer = "Number", stringArray = "List"
        var id: String { rawValue }
    }

    private enum FamilyOption: String, CaseIterable, Identifiable {
        case iPhone = "iPhone", iPad = "iPad", universal = "Universal"
        var id: String { rawValue }
        var families: [Int] {
            switch self {
            case .iPhone: return [1]
            case .iPad: return [2]
            case .universal: return [1, 2]
            }
        }
        static func from(_ families: [Int]) -> FamilyOption {
            families.contains(1) && families.contains(2) ? .universal
                : (families.contains(2) ? .iPad : .iPhone)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.title3).foregroundStyle(.tint)
                Text("Info.plist").font(.headline)
                Spacer()
                if model.hasAdvancedPlistEdits {
                    Button("Reset") { model.resetAdvancedPlistEdits() }.controlSize(.small)
                }
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    compatibility
                    rawEditor
                }
            }

            Divider()
            HStack {
                Text(model.hasAdvancedPlistEdits ? "Changes apply when you sign."
                     : "No changes — the app is signed as-is.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }

    // MARK: Curated options

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compatibility").font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                Text("Minimum iOS").font(.callout).frame(width: 120, alignment: .leading)
                TextField("e.g. 12.0", text: $model.minimumOSVersion)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 100)
                Text("lets it install on older systems — the app may still need newer APIs")
                    .font(.caption2).foregroundStyle(.orange)
                Spacer()
            }

            HStack(spacing: 10) {
                Text("Devices").font(.callout).frame(width: 120, alignment: .leading)
                Picker("", selection: Binding(
                    get: { FamilyOption.from(model.deviceFamilies) },
                    set: { model.deviceFamilies = $0.families })) {
                    ForEach(FamilyOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
            }

            Toggle("Enable file sharing (app's files appear in the Files app)",
                   isOn: $model.fileSharingEnabled)
            Toggle("Allow insecure HTTP connections (App Transport Security off)",
                   isOn: $model.allowArbitraryLoads)
            Toggle("Remove required device capabilities (widens compatibility)",
                   isOn: $model.removeRequiredCapabilities)

            HStack(spacing: 10) {
                Text("URL scheme prefix").font(.callout).frame(width: 120, alignment: .leading)
                TextField("e.g. as1", text: $model.urlSchemePrefix)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 100)
                Text("avoids clashes when installing a second copy")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: Raw keys

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Raw keys").font(.subheadline.weight(.semibold))

            HStack(spacing: 6) {
                TextField("Key", text: $newKey).textFieldStyle(.roundedBorder).controlSize(.small)
                Picker("", selection: $newType) {
                    ForEach(ValueType.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 90)
                TextField(newType == .stringArray ? "a, b, c" : "Value", text: $newValue)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                Button("Add") { addCustomValue() }
                    .controlSize(.small)
                    .disabled(newKey.isEmpty || InfoPlistEditor.protectedKeys.contains(newKey))
            }

            if !model.customPlistValues.isEmpty {
                ForEach(model.customPlistValues.keys.sorted(), id: \.self) { key in
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                        Text(key).font(.callout)
                        Text(describe(model.customPlistValues[key])).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.customPlistValues.removeValue(forKey: key) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            Text("Existing keys — tick to remove").font(.caption).foregroundStyle(.secondary)
            ForEach(model.appPlist.keys.sorted(), id: \.self) { key in
                let locked = InfoPlistEditor.protectedKeys.contains(key)
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { model.removedPlistKeys.contains(key) },
                        set: { on in
                            if on { model.removedPlistKeys.insert(key) }
                            else { model.removedPlistKeys.remove(key) }
                        }))
                        .labelsHidden().disabled(locked)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(key).font(.callout)
                            if locked {
                                Text("required").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.18)))
                            }
                        }
                        Text(preview(model.appPlist[key])).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: Helpers

    private func addCustomValue() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !InfoPlistEditor.protectedKeys.contains(key) else { return }
        let value: PlistValue
        switch newType {
        case .string: value = .string(newValue)
        case .bool: value = .bool(["1", "true", "yes"].contains(newValue.lowercased()))
        case .integer: value = .integer(Int(newValue) ?? 0)
        case .stringArray:
            value = .stringArray(newValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        model.customPlistValues[key] = value
        newKey = ""; newValue = ""
    }

    private func describe(_ value: PlistValue?) -> String {
        switch value {
        case .string(let v): return "\"\(v)\""
        case .bool(let v): return v ? "true" : "false"
        case .integer(let v): return String(v)
        case .stringArray(let v): return "[\(v.joined(separator: ", "))]"
        case nil: return ""
        }
    }

    private func preview(_ value: Any?) -> String {
        switch value {
        case let v as String: return v
        case let v as Bool: return v ? "true" : "false"
        case let v as Int: return String(v)
        case let v as [Any]: return "\(v.count) item(s)"
        case let v as [String: Any]: return "\(v.count) key(s)"
        default: return String(describing: value ?? "")
        }
    }
}
