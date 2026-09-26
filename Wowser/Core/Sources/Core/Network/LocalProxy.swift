#if os(macOS)
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1
import NIOSSL

/// A local intercepting HTTP/HTTPS proxy.
///
/// Webviews are pointed at this proxy via `WKWebsiteDataStore.proxyConfigurations`.
/// HTTP requests are observed and (when the request's origin is on the
/// allowlist in `NetworkCaptureStore`) recorded for the agent to introspect
/// via `browser.net.log` / `browser.net.grep`.
///
/// HTTPS handling: on `CONNECT host:port` we send a 200 to the client, swap
/// the channel pipeline to a TLS server (presenting a forged leaf cert
/// signed by `LocalCA`), then a fresh HTTP server pipeline. The decrypted
/// inner requests flow through the same `LocalProxyHTTPHandler` as plaintext
/// requests, with `mitmHost` set so we know to forward upstream over real TLS.
/// We do *not* bypass cert pinning at the OS level — only our own webviews
/// (which trust our CA via `WKNavigationDelegate`) accept the forged certs.
public actor LocalProxy {
    public static let shared: LocalProxy = LocalProxy(captureStore: NetworkCaptureStore.shared, ca: LocalCA.shared)

    private let captureStore: NetworkCaptureStore
    private let ca: LocalCA
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private(set) public var boundPort: Int?

    /// Thread-safe, synchronously-readable copy of `boundPort`. The webview
    /// data store needs the port at `WebContent.init` time (a synchronous,
    /// non-actor context), so we mirror it here.
    private let portBox = ProxyPortBox()
    public nonisolated var syncBoundPort: Int? { portBox.get() }

    public init(captureStore: NetworkCaptureStore, ca: LocalCA = .shared) {
        self.captureStore = captureStore
        self.ca = ca
    }

    /// Start listening on `127.0.0.1:port`. Pass `port: 0` for an OS-chosen
    /// ephemeral port (useful in tests). Returns the bound port.
    @discardableResult
    public func start(port: Int = 0) async throws -> Int {
        if let p = boundPort { return p }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let store = self.captureStore
        let ca = self.ca
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(LocalProxyHTTPHandler(captureStore: store, ca: ca, mitmHost: nil))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let chan = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        self.channel = chan
        let bound = chan.localAddress?.port ?? port
        self.boundPort = bound
        portBox.set(bound)
        return bound
    }

    public func stop() async {
        if let chan = channel { try? await chan.close() }
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
        boundPort = nil
        portBox.set(nil)
    }
}

/// Lock-protected `Int?` so the proxy's bound port can be read synchronously
/// from outside the actor (see `LocalProxy.syncBoundPort`).
private final class ProxyPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    func get() -> Int? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Int?) { lock.lock(); value = v; lock.unlock() }
}

private final class LocalProxyHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let captureStore: NetworkCaptureStore
    private let ca: LocalCA
    /// When non-nil, all requests received on this pipeline are HTTPS — we've
    /// already MITM-terminated TLS at the channel level and now we forward
    /// upstream over real TLS using the recorded host:port.
    private let mitmHost: (host: String, port: Int)?
    private struct State { var head: HTTPRequestHead; var body: ByteBuffer }
    private var state: State?

    init(captureStore: NetworkCaptureStore, ca: LocalCA, mitmHost: (host: String, port: Int)?) {
        self.captureStore = captureStore
        self.ca = ca
        self.mitmHost = mitmHost
    }

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
            if s.head.method == .CONNECT {
                handleCONNECT(state: s, context: context)
            } else {
                handleHTTP(state: s, context: context)
            }
        }
    }

    // MARK: - HTTP request forwarding

    private func handleHTTP(state: State, context: ChannelHandlerContext) {
        // Plain HTTP: request URI is absolute, e.g. `GET http://x/y`.
        // MITM HTTPS: request URI is relative (after TLS termination, the
        // client is back to ordinary `GET /path` form). Reconstruct the URL.
        let url: URL?
        if let mitm = mitmHost {
            // Build https://<host>[:port]<path>.
            var components = URLComponents()
            components.scheme = "https"
            components.host = mitm.host
            if mitm.port != 443 { components.port = mitm.port }
            // The URI may already include a query string; URLComponents will
            // parse path+query if we set percentEncodedPath/Query separately,
            // but the simplest path is to parse via URL relative to a base.
            let pathOnly = state.head.uri
            if let base = components.url, let abs = URL(string: pathOnly, relativeTo: base) {
                url = abs.absoluteURL
            } else {
                url = components.url
            }
        } else {
            url = absoluteURL(from: state.head)
        }
        guard let url else {
            sendError(context: context, status: .badRequest, message: "bad proxy URL")
            return
        }

        let bodyBytes = state.body.readableBytes > 0
            ? state.body.getBytes(at: 0, length: state.body.readableBytes)
            : nil
        let bodyData = bodyBytes.map(Data.init(_:))

        var req = URLRequest(url: url)
        req.httpMethod = state.head.method.rawValue
        for h in state.head.headers {
            if Self.isHopByHop(h.name) { continue }
            req.addValue(h.value, forHTTPHeaderField: h.name)
        }
        if let bodyData, !bodyData.isEmpty { req.httpBody = bodyData }

        let cfg = URLSessionConfiguration.ephemeral
        // Don't loop through ourselves if the user has a system-wide proxy set.
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg, delegate: LocalCATrustingSessionDelegate(ca: ca), delegateQueue: nil)
        let captureStore = self.captureStore
        let reqBody = bodyData.flatMap { String(data: $0, encoding: .utf8) }
        let isMITM = mitmHost != nil
        nonisolated(unsafe) let ctx = context
        let task = session.dataTask(with: req) { data, response, error in
            ctx.eventLoop.execute {
                guard let http = response as? HTTPURLResponse else {
                    self.sendError(context: ctx, status: .badGateway, message: error?.localizedDescription ?? "upstream error")
                    return
                }
                var headers = HTTPHeaders()
                var respHeaderDict: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    guard let key = k as? String, let val = v as? String else { continue }
                    if Self.isHopByHop(key) { continue }
                    if key.lowercased() == "content-encoding" { continue }
                    if key.lowercased() == "transfer-encoding" { continue }
                    if key.lowercased() == "content-length" { continue }
                    headers.add(name: key, value: val)
                    respHeaderDict[key] = val
                }
                let respData = data ?? Data()
                headers.replaceOrAdd(name: "Content-Length", value: String(respData.count))
                let respHead = HTTPResponseHead(version: state.head.version, status: HTTPResponseStatus(statusCode: http.statusCode), headers: headers)
                ctx.write(self.wrapOutboundOut(.head(respHead)), promise: nil)
                if !respData.isEmpty {
                    var buf = ctx.channel.allocator.buffer(capacity: respData.count)
                    buf.writeBytes(respData)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

                let respBody = String(data: respData, encoding: .utf8) ?? respData.base64EncodedString()
                let reqHeaderDict: [String: String] = state.head.headers.reduce(into: [:]) { acc, h in
                    acc[h.name] = h.value
                }
                let entry = NetCaptureEntry(
                    url: url.absoluteString,
                    method: state.head.method.rawValue,
                    status: http.statusCode,
                    requestHeaders: reqHeaderDict,
                    requestBody: reqBody,
                    responseHeaders: respHeaderDict,
                    responseBody: respBody,
                    tabId: nil,
                    source: isMITM ? "proxy-tls" : "proxy"
                )
                Task { await captureStore.record(entry) }
            }
        }
        task.resume()
    }

    // MARK: - CONNECT (HTTPS — TLS-terminate and recurse on the same handler shape)

    private func handleCONNECT(state: State, context: ChannelHandlerContext) {
        let target = state.head.uri // "host:port"
        let parts = target.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            sendError(context: context, status: .badRequest, message: "bad CONNECT target")
            return
        }
        let host = String(parts[0])

        // Check whether we should MITM this host. We MITM only when (a) the
        // origin is on the capture allowlist AND (b) our root is trusted by the
        // system — WebKit rejects forged certs for proxied TLS otherwise, which
        // would break the page. Without trust we blind-tunnel (loads normally,
        // just uncaptured). Plain `http://` capture needs neither and works
        // through `handleHTTP`. Cert-pinned origins are preserved by tunneling.
        let originSchemeURL = "https://\(host):\(port)"
        let captureStore = self.captureStore
        let ca = self.ca
        nonisolated(unsafe) let ctx = context
        // Run capture-allowlist check on a Task because actor; respond after.
        Task {
            let allowlisted = await captureStore.isCaptureEnabled(forURL: originSchemeURL)
            let rootTrusted = ca.isRootTrusted()
            let captured = allowlisted && rootTrusted
            FileHandle.standardError.write(Data("LocalProxy CONNECT \(host):\(port) -> allowlisted=\(allowlisted) rootTrusted=\(rootTrusted) mitm=\(captured)\n".utf8))
            ctx.eventLoop.execute {
                if captured {
                    self.respondConnectOK(context: ctx, version: state.head.version) {
                        self.startMITM(context: ctx, host: host, port: port)
                    }
                } else {
                    self.startBlindTunnel(context: ctx, host: host, port: port, version: state.head.version)
                }
            }
        }
    }

    /// Sends `200 Connection Established`, then runs `swap` in the write's
    /// completion — on the event loop, before any further client bytes are
    /// read, so the client's TLS ClientHello can never reach the HTTP decoder.
    private func respondConnectOK(context: ChannelHandlerContext, version: HTTPVersion, then swap: @escaping () -> Void) {
        let head = HTTPResponseHead(version: version, status: .ok)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let okPromise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: okPromise)
        okPromise.futureResult.whenComplete { _ in swap() }
    }

    /// Removes everything `configureHTTPServerPipeline()` installed — encoder,
    /// decoder, and NIO's `HTTPServerPipelineHandler`, protocol error handler
    /// and response-headers validator (leaving any of those in place makes
    /// raw TLS bytes trap on their typed `unwrapInboundIn`/`unwrapOutboundIn`)
    /// — plus this handler. (The decoder leaves on the next loop tick; NIO
    /// defers `ByteToMessageHandler` removal.)
    private func removeHTTPServerHandlers(_ sync: ChannelPipeline.SynchronousOperations) throws {
        try sync.removeHandler(context: sync.context(handlerType: HTTPResponseEncoder.self))
        try sync.removeHandler(context: sync.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self))
        if let c = try? sync.context(handlerType: HTTPServerPipelineHandler.self) { try sync.removeHandler(context: c) }
        if let c = try? sync.context(handlerType: HTTPServerProtocolErrorHandler.self) { try sync.removeHandler(context: c) }
        if let c = try? sync.context(handlerType: NIOHTTPResponseHeadersValidator.self) { try sync.removeHandler(context: c) }
        try sync.removeHandler(self)
    }

    // MARK: - MITM path

    private func startMITM(context: ChannelHandlerContext, host: String, port: Int) {
        let clientChannel = context.channel
        let serverContext: NIOSSLContext
        do {
            serverContext = try ca.sslServerContext(forHost: host)
        } catch {
            sendError(context: context, status: .badGateway, message: "MITM ctx error: \(error)")
            return
        }
        let serverHandler = NIOSSLServerHandler(context: serverContext)
        let captureStore = self.captureStore
        let ca = self.ca

        // Swap the pipeline synchronously, still inside the 200's write
        // completion (see `respondConnectOK`): no client bytes can be read
        // between removing the HTTP handlers and installing NIOSSL.
        clientChannel.eventLoop.assertInEventLoop()
        let sync = clientChannel.pipeline.syncOperations
        do {
            try removeHTTPServerHandlers(sync)
            try sync.addHandler(serverHandler, position: .first)
            // Re-install HTTP server pipeline *after* NIOSSL so it
            // operates on the decrypted bytes.
            try sync.configureHTTPServerPipeline()
            try sync.addHandler(LocalProxyHTTPHandler(captureStore: captureStore, ca: ca, mitmHost: (host: host, port: port)))
            FileHandle.standardError.write(Data("LocalProxy MITM swap done for \(host):\(port)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("LocalProxy MITM setup failed: \(error)\n".utf8))
            clientChannel.close(promise: nil)
        }
    }

    // MARK: - Blind tunnel (origins not in the capture allowlist)

    private func startBlindTunnel(context: ChannelHandlerContext, host: String, port: Int, version: HTTPVersion) {
        let clientChannel = context.channel
        let bootstrap = ClientBootstrap(group: clientChannel.eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Connect upstream *before* answering 200: the client starts TLS as
        // soon as it sees the 200, and those bytes must go to the tunnel.
        bootstrap.connect(host: host, port: port).whenComplete { result in
            switch result {
            case .failure:
                self.sendError(context: context, status: .badGateway, message: "tunnel connect failed")
            case .success(let upstream):
                self.respondConnectOK(context: context, version: version) {
                    let sync = clientChannel.pipeline.syncOperations
                    do {
                        try self.removeHTTPServerHandlers(sync)
                        try sync.addHandler(TunnelHandler(peer: upstream))
                        try upstream.pipeline.syncOperations.addHandler(TunnelHandler(peer: clientChannel))
                    } catch {
                        FileHandle.standardError.write(Data("LocalProxy blind tunnel setup failed: \(error)\n".utf8))
                        clientChannel.close(promise: nil)
                        upstream.close(promise: nil)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func absoluteURL(from head: HTTPRequestHead) -> URL? {
        if let url = URL(string: head.uri), url.scheme != nil { return url }
        if let host = head.headers.first(name: "Host") ?? head.headers.first(name: "host") {
            return URL(string: "http://\(host)\(head.uri)")
        }
        return nil
    }

    private func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        let body = ByteBuffer(string: message + "\n")
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "proxy-connection",
    ]
    private static func isHopByHop(_ name: String) -> Bool {
        hopByHop.contains(name.lowercased())
    }
}

/// Bridges raw bytes between two ends of a CONNECT tunnel (used only for
/// origins NOT on the capture allowlist).
private final class TunnelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        peer.writeAndFlush(buf, promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}
#endif
