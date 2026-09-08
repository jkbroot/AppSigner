import XCTest
import Security
@testable import SigningKit

final class OTAServerTests: XCTestCase {
    func testServesTheManifestAndTheIPAOverHTTPS() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ipa = dir.appendingPathComponent("App.ipa")
        let payload = Data("PRETEND-IPA-BYTES".utf8)
        try payload.write(to: ipa)

        let cert = try OTACertificateFactory.generate(ipAddress: "127.0.0.1")
        let server = OTAServer(config: .init(ipaURL: ipa, bundleID: "com.example.demo",
                                             version: "3.1", title: "Demo", port: 0),
                               certificate: cert, host: "127.0.0.1")
        try server.start()
        defer { server.stop() }

        // The manifest carries the app's identity and points at the IPA endpoint.
        let manifest = String(decoding: try get(server.baseURL + "manifest.plist"), as: UTF8.self)
        XCTAssertTrue(manifest.contains("com.example.demo"))
        XCTAssertTrue(manifest.contains(server.baseURL + "app.ipa"))

        // The IPA is served byte-for-byte.
        XCTAssertEqual(try get(server.baseURL + "app.ipa"), payload)

        // The certificate is downloadable so the device can trust it.
        XCTAssertTrue(String(decoding: try get(server.baseURL + "cert.pem"), as: UTF8.self)
            .contains("BEGIN CERTIFICATE"))
    }

    // MARK: HTTPS GET that trusts the server's self-signed certificate

    private func get(_ urlString: String) throws -> Data {
        let url = try XCTUnwrap(URL(string: urlString))
        let delegate = TrustingDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var result: Data?
        var failure: Error?
        let done = expectation(description: "GET \(urlString)")
        session.dataTask(with: url) { data, _, error in
            result = data; failure = error; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    private final class TrustingDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
