import Foundation

/// Locates the workspace assets (the signing profile and source IPAs) by walking up
/// from this source file until a directory containing `AppSigner.mobileprovision` is
/// found. This keeps the tests working whether the Swift package lives at the repo
/// root or nested inside an `AppSigner/` subfolder.
enum Fixtures {
    static let workspaceRoot: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("AppSigner.mobileprovision").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return dir
    }()

    static var profileURL: URL { workspaceRoot.appendingPathComponent("AppSigner.mobileprovision") }

    /// A synthetic, non-sensitive provisioning profile bundled with the tests.
    /// Used by unit tests so they never depend on a real signing profile.
    static var sampleProfileURL: URL {
        Bundle.module.url(forResource: "sample", withExtension: "mobileprovision", subdirectory: "Fixtures")!
    }

    /// Unsigned source IPAs present in the workspace (excludes previously signed outputs).
    static func sourceIPAs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ipa" && !$0.lastPathComponent.contains("_Signed") }
    }
}
