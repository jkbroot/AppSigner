import Foundation

/// One external tool AppSigner may rely on, and how it is kept up to date.
public struct ExternalTool: Identifiable, Equatable {
    public enum Manager: Equatable {
        case homebrew(formula: String)   // updatable via `brew`
        case system                      // ships with macOS / Xcode
        case github(repo: String)        // standalone; updatable from GitHub releases
        case manual(note: String)        // standalone; no update channel
    }
    public let id: String            // binary name used for detection
    public let displayName: String
    public let purpose: String
    public let manager: Manager
    public let versionArg: String?   // argument that prints a version, or nil

    public var formula: String? {
        if case .homebrew(let f) = manager { return f }
        return nil
    }
}

public enum ToolCatalog {
    public static let all: [ExternalTool] = [
        ExternalTool(id: "ideviceinstaller", displayName: "ideviceinstaller",
                     purpose: "Install signed IPAs on a connected device",
                     manager: .homebrew(formula: "ideviceinstaller"), versionArg: "--version"),
        ExternalTool(id: "idevice_id", displayName: "libimobiledevice",
                     purpose: "Detect and talk to connected devices",
                     manager: .homebrew(formula: "libimobiledevice"), versionArg: "-v"),
        ExternalTool(id: "codesign", displayName: "codesign",
                     purpose: "Code signing — Apple system tool (no public alternative)",
                     manager: .system, versionArg: nil),
        ExternalTool(id: "zip", displayName: "zip / unzip",
                     purpose: "IPA packaging — macOS system tools",
                     manager: .system, versionArg: "-v"),
        ExternalTool(id: "optool", displayName: "optool (legacy)",
                     purpose: "Not used — AppSigner injects dylibs natively. Kept only for the old workflow.",
                     manager: .github(repo: "alexzielenski/optool"),
                     versionArg: nil),
    ]

    /// Homebrew formulae referenced by the catalog.
    public static var homebrewFormulae: [String] { all.compactMap { $0.formula } }
}

/// Runtime status of a tool for the Tools panel.
public struct ToolStatus: Identifiable, Equatable {
    public let tool: ExternalTool
    public let installed: Bool
    public let version: String?
    public let updateAvailable: Bool
    public var id: String { tool.id }
}

/// Computes per-tool status from injected lookups (kept pure for testing).
public struct ToolsInspector {
    public init() {}

    public func statuses(findPath: (String) -> String?,
                         version: (ExternalTool) -> String?,
                         outdatedFormulae: Set<String>) -> [ToolStatus] {
        ToolCatalog.all.map { tool in
            let installed = findPath(tool.id) != nil
            let updatable: Bool = {
                guard installed, let f = tool.formula else { return false }
                return outdatedFormulae.contains(f)
            }()
            return ToolStatus(tool: tool,
                              installed: installed,
                              version: installed ? version(tool) : nil,
                              updateAvailable: updatable)
        }
    }
}
