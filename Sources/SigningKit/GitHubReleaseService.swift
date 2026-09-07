import Foundation

/// Reads GitHub release metadata and downloads a release asset. Used to offer updates
/// for standalone tools that are not distributed via Homebrew (e.g. the legacy optool).
public struct GitHubReleaseService {
    public struct Asset: Equatable {
        public let name: String
        public let downloadURL: URL
        public let size: Int
        public init(name: String, downloadURL: URL, size: Int) {
            self.name = name; self.downloadURL = downloadURL; self.size = size
        }
    }
    public struct Release: Equatable {
        public let tag: String
        public let assets: [Asset]
        public init(tag: String, assets: [Asset]) { self.tag = tag; self.assets = assets }
    }

    public enum GitHubError: Error, LocalizedError {
        case network(String), notFound, binaryNotInArchive(String)
        public var errorDescription: String? {
            switch self {
            case .network(let m): return "GitHub request failed: \(m)"
            case .notFound: return "No matching release asset found."
            case .binaryNotInArchive(let n): return "'\(n)' was not found inside the downloaded archive."
            }
        }
    }

    private let runner: ProcessRunner
    public init(runner: ProcessRunner = .init()) { self.runner = runner }

    // MARK: Pure parsing / selection

    public static func parseLatestRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let assets: [Asset] = (obj["assets"] as? [[String: Any]] ?? []).compactMap { a in
            guard let name = a["name"] as? String,
                  let urlStr = a["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else { return nil }
            return Asset(name: name, downloadURL: url, size: a["size"] as? Int ?? 0)
        }
        return Release(tag: tag, assets: assets)
    }

    /// Prefers an asset named exactly `named`, then a `.zip` mentioning it, then the first asset.
    public static func pickBinaryAsset(_ release: Release, named: String) -> Asset? {
        if let exact = release.assets.first(where: { $0.name == named }) { return exact }
        if let zip = release.assets.first(where: {
            $0.name.lowercased().contains(named.lowercased()) && $0.name.lowercased().hasSuffix(".zip")
        }) { return zip }
        return release.assets.first
    }

    // MARK: Network

    public func fetchLatest(repo: String) throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("AppSigner", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try syncData(for: request)
        guard let release = Self.parseLatestRelease(data) else { throw GitHubError.notFound }
        return release
    }

    public func download(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("AppSigner", forHTTPHeaderField: "User-Agent")
        return try syncData(for: request)
    }

    /// Returns the target binary bytes from a downloaded asset, unzipping if needed.
    public func extractBinary(named: String, assetName: String, data: Data) throws -> Data {
        let isZip = assetName.lowercased().hasSuffix(".zip") || data.starts(with: [0x50, 0x4B])  // "PK"
        guard isZip else { return data }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("asset.zip")
        try data.write(to: zipURL)
        try runner.runThrowing("/usr/bin/unzip", ["-q", "-o", zipURL.path, "-d", dir.appendingPathComponent("x").path])

        guard let found = FileManager.default.enumerator(at: dir.appendingPathComponent("x"), includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == named }) else {
            throw GitHubError.binaryNotInArchive(named)
        }
        return try Data(contentsOf: found)
    }

    // MARK: Synchronous URLSession helper

    private func syncData(for request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(GitHubError.network("no response"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(GitHubError.network(error.localizedDescription)) }
            else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(GitHubError.network("HTTP \(http.statusCode)"))
            } else if let data { result = .success(data) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
