#if os(macOS)
import XCTest
@testable import Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

final class NetworkCaptureTests: XCTestCase {

    // MARK: - Store unit tests

    func testStoreRespectsAllowlist() async throws {
        let store = makeStore()
        // Origin not allowlisted — entry is dropped.
        let dropped = await store.record(makeEntry(url: "http://blocked.test/path"))
        let beforeCount = await store.entries(filter: NetLogFilter()).count
        XCTAssertEqual(beforeCount, 0)
        XCTAssertEqual(dropped.url, "http://blocked.test/path") // returned unchanged but not stored

        await store.setCaptureEnabled(origin: "http://allowed.test", enabled: true)
        _ = await store.record(makeEntry(url: "http://allowed.test/foo"))
        let entries = await store.entries(filter: NetLogFilter())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.url, "http://allowed.test/foo")
    }

    func testAllowlistMatchesSubdomains() async throws {
        let store = makeStore()
        await store.setCaptureEnabled(origin: "https://example.com", enabled: true)
        _ = await store.record(makeEntry(url: "https://api.example.com/endpoint"))
        let count = await store.entries(filter: NetLogFilter()).count
        XCTAssertEqual(count, 1)
    }

    func testFilterAndGrep() async throws {
        let store = makeStore()
        await store.setCaptureEnabled(origin: "http://example.test", enabled: true)
        _ = await store.record(makeEntry(url: "http://example.test/a", method: "GET", body: "alpha"))
        _ = await store.record(makeEntry(url: "http://example.test/b", method: "POST", body: "beta"))
        _ = await store.record(makeEntry(url: "http://example.test/c", method: "GET", body: "gamma"))

        let postOnly = await store.entries(filter: NetLogFilter(method: "POST"))
        XCTAssertEqual(postOnly.count, 1)
        XCTAssertEqual(postOnly.first?.method, "POST")

        let grepBeta = await store.grep(pattern: "beta", where: "reqBody")
        XCTAssertEqual(grepBeta.count, 1)
        XCTAssertEqual(grepBeta.first?.url, "http://example.test/b")

        let regex = await store.entries(filter: NetLogFilter(urlRegex: "/[ac]$"))
        XCTAssertEqual(regex.count, 2)
    }

    func testPersistenceRoundtrip() async throws {
        let dir = makeTempDir()
        let s1 = NetworkCaptureStore(directory: dir, keychainService: nil)
        await s1.setCaptureEnabled(origin: "http://persist.test", enabled: true)
        _ = await s1.record(makeEntry(url: "http://persist.test/x"))
        // Spin up a fresh store on the same dir; entry should reload.
        let s2 = NetworkCaptureStore(directory: dir, keychainService: nil)
        let reloaded = await s2.entries(filter: NetLogFilter())
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.url, "http://persist.test/x")
    }

    // MARK: - Proxy + synthetic fetch

    func testProxyCapturesPlaintextHTTP() async throws {
        // 1. Spin up a local origin server.
        let origin = try await TestHTTPServer.start(handler: { method, path, _ in
            return .init(status: 200, headers: ["Content-Type": "text/plain"], body: Data("origin-said-hi method=\(method) path=\(path)".utf8))
        })
        let originPort = await origin.port
        defer { Task { await origin.stop() } }

        // 2. Spin up the local proxy and an isolated capture store.
        let store = makeStore()
        await store.setCaptureEnabled(origin: "http://127.0.0.1:\(originPort)", enabled: true)
        let proxy = LocalProxy(captureStore: store)
        let proxyPort = try await proxy.start(port: 0)
        defer { Task { await proxy.stop() } }

        // 3. Hit the origin through the proxy.
        var cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as AnyHashable: 1,
            kCFNetworkProxiesHTTPProxy as AnyHashable: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as AnyHashable: proxyPort,
        ]
        let session = URLSession(configuration: cfg)
        let url = URL(string: "http://127.0.0.1:\(originPort)/hello")!
        let (data, response) = try await session.data(from: url)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(body.contains("path=/hello"), body)

        // 4. The proxy should have recorded an entry into our store.
        // Race-tolerant: entries land asynchronously after the response fires.
        let captured = try await waitForCount(in: store, atLeast: 1)
        XCTAssertTrue(captured.first!.url.hasSuffix("/hello"))
        XCTAssertEqual(captured.first!.status, 200)
        XCTAssertEqual(captured.first!.source, "proxy")
        XCTAssertTrue((captured.first!.responseBody ?? "").contains("origin-said-hi"), captured.first!.responseBody ?? "")
    }

    func testSyntheticFetchRecordsAndReturns() async throws {
        let origin = try await TestHTTPServer.start(handler: { method, path, body in
            let echoed = "method=\(method) path=\(path) body=\(String(data: body ?? Data(), encoding: .utf8) ?? "")"
            return .init(status: 201, headers: ["Content-Type": "text/plain"], body: Data(echoed.utf8))
        })
        let originPort = await origin.port
        defer { Task { await origin.stop() } }

        let store = makeStore()
        let originURL = "http://127.0.0.1:\(originPort)"
        await store.setCaptureEnabled(origin: originURL, enabled: true)

        let req = NetFetchRequest(url: "\(originURL)/synth", method: "POST", headers: ["X-Test": "yes"], body: "payload", cookiesFrom: nil)
        let resp = try await NetworkSyntheticFetch.fetch(req, captureStore: store)
        XCTAssertEqual(resp.status, 201)
        XCTAssertTrue(resp.body.contains("body=payload"), resp.body)

        let logged = await store.entries(filter: NetLogFilter())
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.source, "synth")
        XCTAssertEqual(logged.first?.requestBody, "payload")
    }

    func testReplayUsesLoggedEntry() async throws {
        let counter = NSLock()
        nonisolated(unsafe) var responseToggle = 0
        let origin = try await TestHTTPServer.start(handler: { _, _, _ in
            counter.lock()
            let n = responseToggle
            responseToggle += 1
            counter.unlock()
            return .init(status: 200, headers: [:], body: Data("attempt-\(n)".utf8))
        })
        let originPort = await origin.port
        defer { Task { await origin.stop() } }

        let store = makeStore()
        let originURL = "http://127.0.0.1:\(originPort)"
        await store.setCaptureEnabled(origin: originURL, enabled: true)

        let first = try await NetworkSyntheticFetch.fetch(
            NetFetchRequest(url: "\(originURL)/r"),
            captureStore: store
        )
        XCTAssertEqual(first.body, "attempt-0")

        let entries = await store.entries(filter: NetLogFilter())
        XCTAssertEqual(entries.count, 1)
        // Re-issue the captured request — the response body should differ on
        // the second hit since the test origin returns a counter.
        let original = entries.first!
        let replay = try await NetworkSyntheticFetch.fetch(
            NetFetchRequest(url: original.url, method: original.method, headers: original.requestHeaders, body: original.requestBody),
            captureStore: store
        )
        XCTAssertEqual(replay.body, "attempt-1")
    }

    // MARK: - Helpers

    private func makeStore() -> NetworkCaptureStore {
        NetworkCaptureStore(directory: makeTempDir(), keychainService: nil)
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wowser-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEntry(url: String, method: String = "GET", body: String? = nil) -> NetCaptureEntry {
        NetCaptureEntry(
            url: url, method: method, status: 200,
            requestHeaders: [:], requestBody: body,
            responseHeaders: [:], responseBody: "ok"
        )
    }

    private func waitForCount(in store: NetworkCaptureStore, atLeast n: Int, timeoutSeconds: Double = 3) async throws -> [NetCaptureEntry] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let entries = await store.entries(filter: NetLogFilter())
            if entries.count >= n { return entries }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for capture entries")
        return await store.entries(filter: NetLogFilter())
    }
}

// MARK: - Test HTTP server

actor TestHTTPServer {
    struct Response { var status: Int; var headers: [String: String]; var body: Data }

    private(set) var port: Int = 0
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    static func start(handler: @escaping @Sendable (_ method: String, _ path: String, _ body: Data?) -> Response) async throws -> TestHTTPServer {
        let server = TestHTTPServer()
        try await server.startInternal(handler: handler)
        return server
    }

    private func startInternal(handler: @escaping @Sendable (String, String, Data?) -> Response) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(TestHTTPServerHandler(handler: handler))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let chan = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = chan
        self.port = chan.localAddress?.port ?? 0
    }

    func stop() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
    }
}

private final class TestHTTPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let handler: @Sendable (String, String, Data?) -> TestHTTPServer.Response
    private struct State { var head: HTTPRequestHead; var body: ByteBuffer }
    private var state: State?

    init(handler: @escaping @Sendable (String, String, Data?) -> TestHTTPServer.Response) { self.handler = handler }

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
