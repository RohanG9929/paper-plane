import Foundation
import Network
import os

/// ffmpeg's only way to the web (security review, Plan 4). ffmpeg reads a web stream from this
/// proxy on 127.0.0.1, which fetches each request itself:
/// - the site's cookie, referer and origin go only to the stream's own site, never to hosts its
///   playlist names elsewhere;
/// - nothing on this Mac or the local network is fetched unless the stream itself is there;
/// - each playlist's addresses point back here, and redirects go back to ffmpeg rewritten, so
///   every hop passes the same checks.
public final class WebProxy: Sendable {
    /// The input as ffmpeg sees it: proxied addresses, and no headers.
    public let input: ResolvedInput
    private let listener: NWListener
    private let refusals: OSAllocatedUnfairLock<Bool>
    private static let log = Logger(subsystem: "dev.paperplane.app", category: "proxy")
    /// A manifest larger than this isn't one Paper Plane will read.
    static let maximumManifest = 16 << 20

    private init(input: ResolvedInput, listener: NWListener, refusals: OSAllocatedUnfairLock<Bool>) {
        self.input = input
        self.listener = listener
        self.refusals = refusals
    }

    /// Whether the site has refused a request (401, 403 or 410): an expired link. ffmpeg skips
    /// segments it can't get and finishes early without saying why; this says why.
    public var siteRefused: Bool {
        refusals.withLock { $0 }
    }

    /// Serves `original`'s web inputs; local files pass through unchanged.
    public static func start(serving original: ResolvedInput) async throws -> WebProxy {
        try await start(serving: original, isLocal: LocalAddresses.isLocal)
    }

    /// The input a proxied request belongs to: its host, the headers the site expects, and
    /// whether the stream itself is on this Mac or the local network.
    private struct Origin: Sendable {
        var host: String
        var headers: [String: String]
        var isLocal: Bool
    }

    /// `isLocal` says whether a host is on this Mac or the local network (tests stand in for it).
    static func start(serving original: ResolvedInput, isLocal: @escaping @Sendable (String) -> Bool) async throws -> WebProxy {
        var origins: [Origin] = []
        for item in original.inputs {
            let host = item.url.host() ?? ""
            origins.append(Origin(host: host, headers: item.headers, isLocal: await offThePool { isLocal(host) }))
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let route = OSAllocatedUnfairLock<ProxyRoute?>(initialState: nil)
        let refusals = OSAllocatedUnfairLock(initialState: false)
        let queue = DispatchQueue(label: "dev.paperplane.web-proxy")
        listener.newConnectionHandler = { [origins] connection in
            connection.start(queue: queue)
            guard let route = route.withLock({ $0 }) else {
                connection.cancel()
                return
            }
            Task { await handle(connection, route: route, origins: origins, isLocal: isLocal, refusals: refusals) }
        }
        try await listener.startAndWaitUntilReady(queue: queue)
        guard let port = listener.port, let base = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/") else {
            listener.cancel()
            throw NWError.posix(.EADDRNOTAVAIL)
        }
        let proxyRoute = ProxyRoute(base: base)
        route.withLock { $0 = proxyRoute }
        let inputs = original.inputs.enumerated().map { index, item in
            guard !item.url.isFileURL, let proxied = proxyRoute.proxied(item.url, input: index) else { return item }
            return ResolvedInput.Input(url: proxied, isHLS: item.isHLS)
        }
        return WebProxy(input: ResolvedInput(inputs: inputs, title: original.title), listener: listener, refusals: refusals)
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: - One request

    private static func handle(_ connection: NWConnection, route: ProxyRoute, origins: [Origin],
                               isLocal: @escaping @Sendable (String) -> Bool, refusals: OSAllocatedUnfairLock<Bool>) async {
        defer { connection.cancel() }
        guard let request = await ProxyRequest.read(from: connection) else { return }
        guard request.method == "GET", let (upstream, index) = route.upstream(for: request.target),
              origins.indices.contains(index), let host = upstream.host()
        else {
            await respond(on: connection, status: 404)
            return
        }
        let origin = origins[index]
        if !origin.isLocal, await offThePool({ isLocal(host) }) {
            log.error("Refused a local address a web stream named")
            await respond(on: connection, status: 502)
            return
        }
        // A site silent for 20 seconds is given up on (ffmpeg's own limit is 30).
        var outgoing = URLRequest(url: upstream, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        outgoing.httpShouldHandleCookies = false
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = request.range {
            outgoing.setValue(range, forHTTPHeaderField: "Range")
        }
        let sameSite = Site.same(host, origin.host)
        for (name, value) in origin.headers where name == "User-Agent" || sameSite {
            outgoing.setValue(value, forHTTPHeaderField: name)
        }
        let response: HTTPURLResponse
        let fetch: UpstreamFetch
        do {
            (response, fetch) = try await UpstreamFetch.start(outgoing)
        } catch {
            await respond(on: connection, status: 502)
            return
        }
        defer { fetch.cancel() }
        if [401, 403, 410].contains(response.statusCode) {
            refusals.withLock { $0 = true }
        }

        if (300..<400).contains(response.statusCode) {
            // Back to ffmpeg, as an address on the proxy: the next hop is checked like the first.
            let location = response.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: upstream)?.absoluteURL }
                .flatMap { route.proxied($0, input: index) }
            await respond(on: connection, status: response.statusCode,
                          headers: location.map { ["Location": $0.absoluteString] } ?? [:])
            return
        }

        var chunks = fetch.body.makeAsyncIterator()
        var start = Data()
        while start.count < 2048, let chunk = try? await chunks.next() {
            start += chunk
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        if (200..<300).contains(response.statusCode),
           let kind = ManifestRewriter.kind(contentType: contentType, url: upstream, start: start) {
            var body = start
            while let chunk = try? await chunks.next() {
                body += chunk
                guard body.count <= maximumManifest else {
                    await respond(on: connection, status: 502)
                    return
                }
            }
            let rewritten = ManifestRewriter.rewrite(String(decoding: body, as: UTF8.self), kind: kind, from: upstream,
                                                     input: index, route: route)
            // Named for what it is, whatever the site called it.
            let type = kind == .hls ? "application/vnd.apple.mpegurl" : "application/dash+xml"
            await respond(on: connection, status: response.statusCode, headers: ["Content-Type": type],
                          body: Data(rewritten.utf8))
            return
        }

        // Anything else streams through, with what ffmpeg needs to seek in it.
        var headers: [String: String] = [:]
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
            headers[name] = response.value(forHTTPHeaderField: name)
        }
        guard await send(head(status: response.statusCode, headers: headers) + start, on: connection) else { return }
        while let chunk = try? await chunks.next() {
            guard await send(chunk, on: connection) else { return } // ffmpeg hung up
        }
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
        let lines = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        return Data("HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n\(lines)Connection: close\r\n\r\n".utf8)
    }

    private static func respond(on connection: NWConnection, status: Int, headers: [String: String] = [:],
                                body: Data = Data()) async {
        var headers = headers
        headers["Content-Length"] = String(body.count)
        _ = await send(head(status: status, headers: headers) + body, on: connection)
    }

    private static func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    /// Runs blocking work (name lookups) on a thread of its own.
    private static func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }
}

/// The request line and the Range header of what ffmpeg asked the proxy for.
struct ProxyRequest: Equatable {
    var method: String
    var target: String
    var range: String?

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3 else { return nil }
        method = String(parts[0])
        target = String(parts[1])
        range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
    }

    /// Reads up to the end of the request's headers (at most 16 KB).
    static func read(from connection: NWConnection) async -> ProxyRequest? {
        var buffer = Data()
        while buffer.count < 16 * 1024 {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return ProxyRequest(head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            }
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                    continuation.resume(returning: error == nil ? data : nil)
                }
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            buffer += chunk
        }
        return nil
    }
}

/// One upstream request, its response as soon as the headers arrive and its body as it comes.
/// Redirects aren't followed here: they go back to ffmpeg through the proxy.
final class UpstreamFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let body: AsyncThrowingStream<Data, any Error>
    private let chunks: AsyncThrowingStream<Data, any Error>.Continuation
    private let waiting = OSAllocatedUnfairLock<CheckedContinuation<HTTPURLResponse, any Error>?>(initialState: nil)
    private let followsRedirects: Bool
    /// Set once in `begin`, before anything else can touch them.
    private var session: URLSession?
    private var task: URLSessionDataTask?

    /// The proxy hands redirects back to ffmpeg; the yt-dlp updater has them followed
    /// (`followsRedirects`), though never from HTTPS to plain HTTP.
    static func start(_ request: URLRequest, followsRedirects: Bool = false) async throws -> (HTTPURLResponse, UpstreamFetch) {
        let fetch = UpstreamFetch(followsRedirects: followsRedirects)
        let response = try await withCheckedThrowingContinuation { continuation in
            fetch.waiting.withLock { $0 = continuation }
            fetch.begin(request)
        }
        return (response, fetch)
    }

    private init(followsRedirects: Bool) {
        var chunks: AsyncThrowingStream<Data, any Error>.Continuation?
        body = AsyncThrowingStream { chunks = $0 }
        self.chunks = chunks!
        self.followsRedirects = followsRedirects
        super.init()
    }

    private func begin(_ request: URLRequest) {
        // Nothing kept: no cookie store, no cache.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        task.resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    private func answer(_ result: Result<HTTPURLResponse, any Error>) {
        let continuation = waiting.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let downgrade = Self.isDowngrade(from: task.originalRequest?.url, to: request.url)
        completionHandler(followsRedirects && !downgrade ? request : nil)
    }

    /// From HTTPS to anything less.
    static func isDowngrade(from original: URL?, to next: URL?) -> Bool {
        original?.scheme?.lowercased() == "https" && next?.scheme?.lowercased() != "https"
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            answer(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        answer(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunks.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error == nil, let response = task.response as? HTTPURLResponse {
            answer(.success(response)) // a redirect not followed arrives without didReceive
        } else {
            answer(.failure(error ?? URLError(.badServerResponse)))
        }
        if let error {
            chunks.finish(throwing: error)
        } else {
            chunks.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
