import Foundation

/// A developer tool that can be injected into an app being signed.
///
/// AppSigner never ships or downloads these binaries: each one is built from its own
/// source on this machine, or pointed at a copy you already have.
public struct DeveloperTool: Identifiable, Equatable {
    public enum Artifact: Equatable {
        case framework(String)
        case dylib(String)
        public var fileName: String {
            switch self { case .framework(let name), .dylib(let name): return name }
        }
        public var isFramework: Bool {
            if case .framework = self { return true }
            return false
        }
    }

    public let id: String
    public let name: String
    public let summary: String
    public let repository: String
    public let license: String
    /// How the user opens the tool once the app is running.
    public let triggerHint: String?
    /// What has to be present for the tool to be usable.
    public let artifacts: [Artifact]
}

public enum DeveloperToolCatalog {
    public static let all: [DeveloperTool] = [
        DeveloperTool(
            id: "flex",
            name: "FLEX",
            summary: """
            An in-app debugger: browse the view hierarchy, every loaded class, live objects \
            and their properties, network requests, the app sandbox and its databases — and \
            edit them while the app runs.
            """,
            repository: "https://github.com/FLEXTool/FLEX",
            license: "BSD-3-Clause",
            triggerHint: "Three-finger long press anywhere in the app.",
            artifacts: [.framework("FLEX.framework"), .dylib("FLEXBootstrap.dylib")]
        ),
    ]
}

public struct DeveloperToolStatus {
    public let tool: DeveloperTool
    /// Artifact file names that are not present yet.
    public let missing: [String]
    public var isReady: Bool { missing.isEmpty }
}

/// Where built developer tools live on this machine — one folder per tool.
public struct DeveloperToolLibrary {
    public let directory: URL

    /// Defaults to `~/Library/Application Support/AppSigner/Tools`.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("AppSigner/Tools", isDirectory: true)
        }
    }

    public func folder(for tool: DeveloperTool) -> URL {
        directory.appendingPathComponent(tool.id, isDirectory: true)
    }

    public func status(for tool: DeveloperTool) -> DeveloperToolStatus {
        let root = folder(for: tool)
        let missing = tool.artifacts
            .map(\.fileName)
            .filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        return DeveloperToolStatus(tool: tool, missing: missing)
    }

    public func frameworks(for tool: DeveloperTool) -> [URL] {
        urls(for: tool) { $0.isFramework }
    }

    public func dylibs(for tool: DeveloperTool) -> [URL] {
        urls(for: tool) { !$0.isFramework }
    }

    private func urls(for tool: DeveloperTool,
                      matching predicate: (DeveloperTool.Artifact) -> Bool) -> [URL] {
        let root = folder(for: tool)
        return tool.artifacts.filter(predicate)
            .map { root.appendingPathComponent($0.fileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Adopts artifacts the user already built, copying them out of `source`.
    public func importArtifacts(for tool: DeveloperTool, from source: URL) throws {
        let fm = FileManager.default
        let root = folder(for: tool)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for artifact in tool.artifacts {
            let from = source.appendingPathComponent(artifact.fileName)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = root.appendingPathComponent(artifact.fileName)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }
    }

    public func remove(_ tool: DeveloperTool) throws {
        try? FileManager.default.removeItem(at: folder(for: tool))
    }
}
