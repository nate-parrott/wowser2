#if os(macOS)
import XCTest
@testable import Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
import NIOSSL

/// End-to-end test that the local proxy can MITM HTTPS: forge a leaf cert
/// signed by our LocalCA, terminate TLS on the inbound side, parse the inner
/// HTTP, log it to NetworkCaptureStore, and forward upstream.
final class HTTPSCaptureTests: XCTestCase {

    func testProxyMITMCapturesHTTPSRequest() async throws {
        // Use an isolated CA so this test doesn't pollute the user's keychain.
        let caDir = FileManager.default.temporaryDirectory.appendingPathComponent("wowser-test-ca-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: caDir, withIntermediateDirectories: true)
        let ca = LocalCA(keychainService: "com.wowser.test-ca-\(UUID().uuidString)")
        _ = try ca.ensureRoot()

        // 1. Spin up a local HTTPS origin. It uses a leaf cert signed by our
        //    test CA — the proxy's URLSession forwarder trusts that CA via
        //    LocalCATrustingSessionDelegate, so the inner forward leg works.
        let origin = try await TestHTTPSServer.start(ca: ca, host: "127.0.0.1") { method, path, body in
            let echoed = "HTTPS: method=\(method) path=\(path) body=\(String(data: body ?? Data(), encoding: .utf8) ?? "")"
            return .init(status: 200, headers: ["Content-Type": "text/plain"], body: Data(echoed.utf8))
        }
        let originPort = await origin.port
        defer { Task { await origin.stop() } }

        // 2. Spin up the proxy with an isolated capture store, allowlist the origin.
        let store = NetworkCaptureStore(directory: caDir, keychainService: nil)
        await store.setCaptureEnabled(origin: "https://127.0.0.1:\(originPort)", enabled: true)
        let proxy = LocalProxy(captureStore: store, ca: ca)
        let proxyPort = try await proxy.start(port: 0)
        defer { Task { await proxy.stop() } }

        // 3. Drive the proxy directly via NIO. URLSession bypasses proxies for
        //    loopback destinations by default (and in headless test contexts
        //    silently ignores `connectionProxyDictionary`), so we synthesize
        //    the CONNECT + TLS handshake ourselves to get a deterministic test.
        let result = try await ProxyClient.send(
            proxyHost: "127.0.0.1", proxyPort: proxyPort,
            originHost: "127.0.0.1", originPort: originPort,
            method: "POST", path: "/secret-path?q=1",
            body: "hello-from-client", ca: ca
        )
        FileHandle.standardError.write(Data("HTTPSCaptureTests got status=\(result.status) body=\(result.body)\n".utf8))
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.body.contains("path=/secret-path"), "got: \(result.body)")
        XCTAssertTrue(result.body.contains("body=hello-from-client"), "got: \(result.body)")

        // 4. Verify the proxy MITM-decrypted the inner request and logged it.
        try await Task.sleep(nanoseconds: 500_000_000)
        let entries = await store.entries(filter: NetLogFilter())
        FileHandle.standardError.write(Data("HTTPSCaptureTests entries.count=\(entries.count) sources=\(entries.map { $0.source })\n".utf8))
        let mitmEntries = entries.filter { $0.source == "proxy-tls" }
        XCTAssertFalse(mitmEntries.isEmpty, "expected a proxy-tls log entry, got entries: \(entries.map { "\($0.source):\($0.url)" })")
        guard let entry = mitmEntries.first else { return }
        XCTAssertTrue(entry.url.contains("/secret-path"), entry.url)
        XCTAssertEqual(entry.method, "POST")
        XCTAssertEqual(entry.requestBody, "hello-from-client")
        XCTAssertTrue((entry.responseBody ?? "").contains("body=hello-from-client"), entry.responseBody ?? "")
    }

    func testProxyTunnelsCertPinnedHostsWithoutMITM() async throws {
        // If the origin is NOT on the capture allowlist, the proxy must
        // tunnel CONNECT verbatim — preserving the upstream's real cert so
        // pinning continues to work. We verify by checking that a forwarded
        // request returns the upstream's cert (not our MITM leaf), which we
        // approximate by confirming no log entry is recorded.
        let caDir = FileManager.default.temporaryDirectory.appendingPathComponent("wowser-test-ca-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: caDir, withIntermediateDirectories: true)
        let ca = LocalCA(keychainService: "com.wowser.test-ca-\(UUID().uuidString)")
        _ = try ca.ensureRoot()

        let origin = try await TestHTTPSServer.start(ca: ca, host: "127.0.0.1") { _, _, _ in
            .init(status: 200, headers: [:], body: Data("plain".utf8))
        }
        let originPort = await origin.port
        defer { Task { await origin.stop() } }

        let store = NetworkCaptureStore(directory: caDir, keychainService: nil)
        // Deliberately do NOT add the origin to the allowlist.
        let proxy = LocalProxy(captureStore: store, ca: ca)
        let proxyPort = try await proxy.start(port: 0)
        defer { Task { await proxy.stop() } }

        let result = try await ProxyClient.send(
            proxyHost: "127.0.0.1", proxyPort: proxyPort,
            originHost: "127.0.0.1", originPort: originPort,
            method: "GET", path: "/p", body: nil, ca: ca
        )
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, "plain")

        // No log entries — origin was not allowlisted, so we tunneled raw bytes.
        try await Task.sleep(nanoseconds: 300_000_000)
        let logged = await store.entries(filter: NetLogFilter())
        XCTAssertEqual(logged.count, 0, "captured \(logged.count) entries; expected 0 because origin wasn't allowlisted")
    }

    // MARK: - Helpers

    private func waitForCount(in store: NetworkCaptureStore, atLeast n: Int, timeoutSeconds: Double = 5) async throws -> [NetCaptureEntry] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let entries = await store.entries(filter: NetLogFilter())
            if entries.count >= n { return entries }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(n) capture entries; got \(await store.entries(filter: NetLogFilter()).count)")
        return await store.entries(filter: NetLogFilter())
    }
}

// MARK: - Manual proxy client (TCP -> CONNECT -> TLS -> HTTP)
//
// URLSession bypasses proxies for loopback destinations and silently ignores
// `connectionProxyDictionary` in some headless contexts. To get a deterministic
// integration test, we drive the proxy directly with NIO: open TCP, do
// CONNECT, upgrade to TLS that trusts our LocalCA, send an HTTP/1.1 request,
// collect the body. This exercises the same code path real browsers do.

enum ProxyClient {
    struct Result { var status: Int; var body: String }

    static func send(proxyHost: String, proxyPort: Int,
                     originHost: String, originPort: Int,
                     method: String, path: String, body: String?,
                     ca: LocalCA) async throws -> Result {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // 1. TCP connect to the proxy.
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // We will install handlers in two stages: first a raw byte buffer
        // collector that consumes the CONNECT response, then swap to TLS+HTTP.
        let connectReceiver = ConnectResponseHandler()
        let channel = try await bootstrap.channelInitializer { ch in
            ch.pipeline.addHandler(connectReceiver)
        }.connect(host: proxyHost, port: proxyPort).get()

        // 2. Send CONNECT.
        let connectLine = "CONNECT \(originHost):\(originPort) HTTP/1.1\r\nHost: \(originHost):\(originPort)\r\n\r\n"
        var buf = channel.allocator.buffer(capacity: connectLine.utf8.count)
        buf.writeString(connectLine)
        try await channel.writeAndFlush(buf).get()

        // 3. Wait for the 200.
        let connectStatus = try await connectReceiver.waitForStatus()
        guard connectStatus == 200 else {
            try? await channel.close()
            throw NSError(domain: "ProxyClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "CONNECT returned \(connectStatus)"])
        }

        // 4. Swap pipeline: drop the receiver, install TLS client (trusting
        //    our LocalCA via the same `LocalCATrust` evaluator used in
        //    production code paths), then HTTP client + collector.
        try await channel.pipeline.removeHandler(connectReceiver).get()

        // Build a NIOSSL client that trusts our LocalCA's root.
        let rootSec = try ca.rootSecCertificate()
        let rootCertData = SecCertificateCopyData(rootSec) as Data
        let rootNIO = try NIOSSLCertificate(bytes: Array(rootCertData), format: .der)
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = .certificates([rootNIO])
        // We connect by IP literal (127.0.0.1). NIOSSL refuses to put IP
        // addresses into SNI, so pass nil for serverHostname — chain is
        // still validated against the trust roots above.
        tlsConfig.certificateVerification = .noHostnameVerification
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
        try await channel.pipeline.addHandler(sslHandler).get()

        // HTTP client pipeline + a collector.
        try await channel.pipeline.addHTTPClientHandlers().get()
        let collector = HTTPResponseCollector()
        try await channel.pipeline.addHandler(collector).get()

        // 5. Issue the HTTP/1.1 request.
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(originHost):\(originPort)")
        if let body { headers.add(name: "Content-Length", value: String(body.utf8.count)) }
        headers.add(name: "Connection", value: "close")
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: path, headers: headers)
        try await channel.writeAndFlush(NIOAny(HTTPClientRequestPart.head(head))).get()
        if let body, !body.isEmpty {
            var bodyBuf = channel.allocator.buffer(capacity: body.utf8.count)
            bodyBuf.writeString(body)
            try await channel.writeAndFlush(NIOAny(HTTPClientRequestPart.body(.byteBuffer(bodyBuf)))).get()
        }
        try await channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).get()

        // 6. Wait for response.
        let response = try await collector.waitForResponse(timeout: 5)
        try? await channel.close()
        return Result(status: response.status, body: response.body)
    }
}

private final class ConnectResponseHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var buffer: String = ""
    private var continuation: CheckedContinuation<Int, Error>?

    func waitForStatus() async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            continuation = cont
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let str = buf.readString(length: buf.readableBytes) {
            buffer += str
        }
        // Look for end of CONNECT response (\r\n\r\n).
        if buffer.contains("\r\n\r\n") {
            // First line: "HTTP/1.1 <status> ..."
            let firstLine = buffer.split(separator: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let status = (parts.count >= 2) ? Int(parts[1]) ?? 0 : 0
            continuation?.resume(returning: status)
            continuation = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        context.close(promise: nil)
    }
}

private final class HTTPResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    struct Response { var status: Int; var body: String }

    private let lock = NSLock()
    private var status = 0
    private var bodyBuf = ""
    private var continuation: CheckedContinuation<Response, Error>?

    func waitForResponse(timeout: Double) async throws -> Response {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            lock.lock(); status = Int(head.status.code); lock.unlock()
        case .body(var buf):
            if let s = buf.readString(length: buf.readableBytes) {
                lock.lock(); bodyBuf += s; lock.unlock()
            }
        case .end:
            lock.lock()
            let resp = Response(status: status, body: bodyBuf)
            let cont = continuation; continuation = nil
            lock.unlock()
            cont?.resume(returning: resp)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.lock()
        let cont = continuation; continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        if continuation != nil {
            let resp = Response(status: status, body: bodyBuf)
            let cont = continuation; continuation = nil
            lock.unlock()
            cont?.resume(returning: resp)
        } else {
            lock.unlock()
        }
    }
}

// MARK: - URLSession delegate that trusts a specific LocalCA

private final class MITMTestSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let ca: LocalCA
    init(ca: LocalCA) { self.ca = ca }
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { completionHandler(.performDefaultHandling, nil); return }
        if LocalCATrust.trustIsValid(trust, allowingLocalCA: ca) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - HTTPS test server (NIOSSL with a LocalCA-issued leaf)

actor TestHTTPSServer {
    struct Response { var status: Int; var headers: [String: String]; var body: Data }

    private(set) var port: Int = 0
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    static func start(ca: LocalCA, host: String, handler: @escaping @Sendable (_ method: String, _ path: String, _ body: Data?) -> Response) async throws -> TestHTTPSServer {
        let s = TestHTTPSServer()
        try await s.startInternal(ca: ca, host: host, handler: handler)
        return s
    }

    private func startInternal(ca: LocalCA, host: String, handler: @escaping @Sendable (String, String, Data?) -> Response) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        // Reuse the LocalCA to mint a leaf for the test host. Same code path
        // the proxy uses — proves the cert plumbing works.
        let sslContext = try ca.sslServerContext(forHost: host)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                let tlsHandler = NIOSSLServerHandler(context: sslContext)
                return ch.pipeline.addHandler(tlsHandler).flatMap {
                    ch.pipeline.configureHTTPServerPipeline()
                }.flatMap {
                    ch.pipeline.addHandler(TestHTTPSServerHandler(handler: handler))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let chan = try await bootstrap.bind(host: host, port: 0).get()
        self.channel = chan
        self.port = chan.localAddress?.port ?? 0
    }

    func stop() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
    }
}

private final class TestHTTPSServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let handler: @Sendable (String, String, Data?) -> TestHTTPSServer.Response
    private struct State { var head: HTTPRequestHead; var body: ByteBuffer }
    private var state: State?

    init(handler: @escaping @Sendable (String, String, Data?) -> TestHTTPSServer.Response) { self.handler = handler }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state = State(head: head, body: context.channel.allocator.buffer(capacity: 0))
        case .body(var buf):
            state?.body.writeBuffer(&buf)
        case .end:
            guard let s = state else { return }
            state = nil
            let bodyData: Data? = s.body.readableBytes > 0
                ? Data(s.body.getBytes(at: 0, length: s.body.readableBytes) ?? [])
                : nil
            let path = String(s.head.uri.split(separator: "?").first ?? Substring(s.head.uri))
            let resp = handler(s.head.method.rawValue, path, bodyData)
            var headers = HTTPHeaders()
            for (k, v) in resp.headers { headers.add(name: k, value: v) }
            headers.replaceOrAdd(name: "Content-Length", value: String(resp.body.count))
            let head = HTTPResponseHead(version: s.head.version, status: HTTPResponseStatus(statusCode: resp.status), headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if !resp.body.isEmpty {
                var buf = context.channel.allocator.buffer(capacity: resp.body.count)
                buf.writeBytes(resp.body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
#endif
