import Foundation
import Network

/// A small local HTTPS server that hosts a signed IPA for an over-the-air install.
///
/// It serves four things over TLS (using a self-signed identity):
/// `/` a landing page, `/cert.pem` the certificate to trust, `/manifest.plist` the
/// itms-services manifest, and `/app.ipa` the app itself. Everything stays on the local
/// network — nothing is exposed to the internet.
public final class OTAServer {
    public struct Config {
        public let ipaURL: URL
        public let bundleID: String
        public let version: String
        public let title: String
        /// Desired port, or 0 to bind an ephemeral one.
        public let port: UInt16
        public init(ipaURL: URL, bundleID: String, version: String, title: String, port: UInt16 = 8843) {
            self.ipaURL = ipaURL; self.bundleID = bundleID; self.version = version
            self.title = title; self.port = port
        }
    }

    public enum ServerError: Error { case identityUnusable, startTimeout }

    private let config: Config
    private let identity: SecIdentity
    private let certificatePEM: Data
    private let host: String
    private let queue = DispatchQueue(label: "com.jkbcoder.appsigner.ota", attributes: .concurrent)
    private var listener: NWListener?
    public private(set) var boundPort: UInt16 = 0

    public init(config: Config, certificate: OTACertificate, host: String) {
        self.config = config
        self.identity = certificate.identity
        self.certificatePEM = certificate.certificatePEM
        self.host = host
    }

    /// `https://<ip>:<port>/` — valid only after `start()`.
    public var baseURL: String { "https://\(host):\(boundPort)/" }
    /// The link Safari opens to begin the install.
    public var installURL: String { "itms-services://?action=download-manifest&url=\(baseURL)manifest.plist" }

    public func start() throws {
        guard let secIdentity = sec_identity_create(identity) else { throw ServerError.identityUnusable }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true

        let listener = config.port == 0
            ? try NWListener(using: params)
            : try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.port)!)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .cancelled: ready.signal()
            case .failed(let error): startError = error; ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { throw ServerError.startTimeout }
        if let startError { throw startError }
        boundPort = listener.port?.rawValue ?? config.port
    }

    public func stop() { listener?.cancel(); listener = nil }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                self.route(conn, path: Self.path(fromRequest: head))
            } else if error != nil || isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func route(_ conn: NWConnection, path: String) {
        switch path {
        case "/":
            send(conn, contentType: "text/html; charset=utf-8", body: Data(landingPage.utf8))
        case "/manifest.plist":
            let manifest = OTAManifest.plist(ipaURL: "\(baseURL)app.ipa", bundleID: config.bundleID,
                                             version: config.version, title: config.title)
            send(conn, contentType: "application/xml", body: Data(manifest.utf8))
        case "/cert.pem":
            send(conn, contentType: "application/x-x509-ca-cert", body: certificatePEM)
        case "/app.ipa":
            sendFile(conn, url: config.ipaURL, contentType: "application/octet-stream")
        default:
            send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
        }
    }

    // MARK: Responses

    private func send(_ conn: NWConnection, status: String = "200 OK", contentType: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Streams a (potentially large) file in chunks so the whole IPA is never held in memory.
    private func sendFile(_ conn: NWConnection, url: URL, contentType: String) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            send(conn, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
            return
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(size)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.streamChunk(conn, handle: handle)
        })
    }

    private func streamChunk(_ conn: NWConnection, handle: FileHandle) {
        let chunk = handle.readData(ofLength: 1 << 16)
        if chunk.isEmpty { try? handle.close(); conn.cancel(); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); conn.cancel(); return }
            self?.streamChunk(conn, handle: handle)
        })
    }

    // MARK: Helpers

    private static func path(fromRequest head: String) -> String {
        let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"
    }

    private var landingPage: String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(config.title))</title>
        <style>
          body{font:-apple-system-body,system-ui,sans-serif;margin:0;padding:32px 20px;
               background:#0b0b0c;color:#eee;text-align:center}
          h1{font-size:22px;margin:0 0 4px} .v{color:#888;margin-bottom:28px}
          a.btn{display:block;margin:12px auto;max-width:320px;padding:15px;border-radius:12px;
                text-decoration:none;font-weight:600;font-size:17px}
          .cert{background:#2a2a2e;color:#fff} .app{background:#0a84ff;color:#fff}
          ol{max-width:340px;margin:26px auto;text-align:left;color:#aaa;font-size:14px;line-height:1.6}
        </style></head><body>
        <h1>\(htmlEscape(config.title))</h1>
        <div class="v">\(htmlEscape(config.bundleID)) · \(htmlEscape(config.version))</div>
        <a class="btn cert" href="/cert.pem">1 · Install the certificate</a>
        <a class="btn app" href="\(installURL)">2 · Install the app</a>
        <ol>
          <li>Tap <b>Install the certificate</b>, then trust it in
              Settings → General → VPN &amp; Device Management, and enable it under
              Settings → General → About → Certificate Trust Settings.</li>
          <li>Tap <b>Install the app</b> and confirm.</li>
        </ol>
        </body></html>
        """
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Local network address

    /// The Mac's LAN IPv4 address on a Wi-Fi/Ethernet interface, if any.
    public static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
                break
            }
        }
        return address
    }
}
