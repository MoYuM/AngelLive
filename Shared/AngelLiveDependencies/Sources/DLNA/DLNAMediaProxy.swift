import Foundation
import AngelLiveCore
import NIO
import NIOHTTP1

#if canImport(Darwin)
import Darwin
#endif

/// A short-lived, token-gated HTTP endpoint that lets a DLNA renderer consume
/// streams which require request headers. The renderer never sees the origin URL.
public actor DLNALocalMediaProxy {
    public static let shared = DLNALocalMediaProxy()

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let store = DLNAMediaProxyStore()
    private var serverChannel: Channel?
    private var baseURL: URL?

    public init() {}

    public func prepare(resource: DLNAMediaResource) async throws -> DLNAMediaResource {
        guard resource.requiresLocalProxy else { return resource }
        let baseURL = try await startIfNeeded()
        let token = store.register(headers: resource.requestHeaders)
        guard let proxyURL = store.proxyURL(for: resource.url, token: token, baseURL: baseURL) else {
            store.remove(token: token)
            throw DLNAProxyError.invalidOriginURL
        }
        return DLNAMediaResource(
            url: proxyURL,
            title: resource.title,
            mimeType: resource.mimeType,
            isLive: resource.isLive
        )
    }

    public func release(resource: DLNAMediaResource) {
        store.remove(token: store.token(in: resource.url))
    }

    public func stop() async {
        store.removeAll()
        guard let serverChannel else { return }
        self.serverChannel = nil
        self.baseURL = nil
        try? await serverChannel.close()
    }

    private func startIfNeeded() async throws -> URL {
        if let baseURL, serverChannel?.isActive == true { return baseURL }

        let store = self.store
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(DLNAMediaProxyHTTPHandler(store: store))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        guard let port = channel.localAddress?.port,
              let host = Self.localIPv4Address() else {
            try? await channel.close()
            throw DLNAProxyError.localAddressUnavailable
        }
        guard let url = URL(string: "http://\(host):\(port)") else {
            try? await channel.close()
            throw DLNAProxyError.localAddressUnavailable
        }
        serverChannel = channel
        baseURL = url
        return url
    }

    private static func localIPv4Address() -> String? {
        #if canImport(Darwin)
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [(name: String, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let bytes = host.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }
            let value = String(decoding: bytes, as: UTF8.self)
            let name = String(cString: item.pointee.ifa_name)
            candidates.append((name, value))
        }

        return candidates.first(where: { $0.name == "en0" })?.address
            ?? candidates.first(where: { $0.name.hasPrefix("en") })?.address
            ?? candidates.first?.address
        #else
        return nil
        #endif
    }
}

public enum DLNAProxyError: Error, LocalizedError, Sendable, Equatable {
    case localAddressUnavailable
    case invalidOriginURL
    case upstreamUnavailable

    public var errorDescription: String? {
        switch self {
        case .localAddressUnavailable: return "无法获取手机的局域网地址，电视无法连接本地媒体代理"
        case .invalidOriginURL: return "投屏播放地址无效"
        case .upstreamUnavailable: return "播放源连接失败"
        }
    }
}

private final class DLNAMediaProxyStore: @unchecked Sendable {
    private struct Entry {
        let headers: [String: String]
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(headers: [String: String]) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        lock.lock()
        entries = entries.filter { $0.value.expiresAt > Date() }
        entries[token] = Entry(headers: headers, expiresAt: Date().addingTimeInterval(24 * 60 * 60))
        lock.unlock()
        return token
    }

    func headers(for token: String) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token], entry.expiresAt > Date() else {
            entries.removeValue(forKey: token)
            return nil
        }
        return entry.headers
    }

    func remove(token: String?) {
        guard let token, !token.isEmpty else { return }
        lock.lock()
        entries.removeValue(forKey: token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func token(in url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parts = components?.path.split(separator: "/").map(String.init) ?? []
        guard parts.count >= 3, parts[0] == "dlna", parts[2] == "fetch" else { return nil }
        return parts[1]
    }

    func proxyURL(for origin: URL, token: String, baseURL: URL) -> URL? {
        guard origin.scheme?.lowercased() == "http" || origin.scheme?.lowercased() == "https" else { return nil }
        let encoded = Data(origin.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(url: baseURL.appendingPathComponent("dlna").appendingPathComponent(token).appendingPathComponent("fetch"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "url", value: encoded)]
        return components?.url
    }
}

private final class DLNAMediaProxyHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: DLNAMediaProxyStore
    private var requestHead: HTTPRequestHead?
    private var upstream: DLNAProxyUpstreamRequest?

    init(store: DLNAMediaProxyStore) { self.store = store }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            guard head.method == .GET || head.method == .HEAD else {
                sendError(context: context, status: .methodNotAllowed)
                return
            }
            guard let target = DLNAMediaProxyRequestTarget(uri: head.uri, host: head.headers.first(name: "Host")),
                  let headers = store.headers(for: target.token) else {
                sendError(context: context, status: .notFound)
                return
            }
            let request = DLNAProxyUpstreamRequest(
                channel: context.channel,
                method: head.method,
                originURL: target.originURL,
                headers: headers,
                range: head.headers.first(name: "Range"),
                token: target.token,
                proxyURL: { [store] url, token, base in store.proxyURL(for: url, token: token, baseURL: base) },
                baseURL: target.baseURL
            )
            upstream = request
            request.start()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.cancel()
    }

    private func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private struct DLNAMediaProxyRequestTarget {
    let token: String
    let originURL: URL
    let baseURL: URL

    init?(uri: String, host: String?) {
        guard let components = URLComponents(string: uri) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "dlna", parts[2] == "fetch",
              let token = parts[safe: 1], !token.isEmpty,
              let encoded = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let originURL = Self.decode(encoded),
              let host, let baseURL = URL(string: "http://\(host)") else { return nil }
        self.token = token
        self.originURL = originURL
        self.baseURL = baseURL
    }

    private static func decode(_ value: String) -> URL? {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let string = String(data: data, encoding: .utf8),
              let url = URL(string: string),
              url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

private final class DLNAProxyUpstreamRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let channel: Channel
    private let method: NIOHTTP1.HTTPMethod
    private let originURL: URL
    private let requestHeaders: [String: String]
    private let range: String?
    private let token: String
    private let makeProxyURL: (URL, String, URL) -> URL?
    private let baseURL: URL
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var responseSent = false
    private var isPlaylist = false
    private var playlistData = Data()
    private var finalURL: URL

    init(
        channel: Channel,
        method: NIOHTTP1.HTTPMethod,
        originURL: URL,
        headers: [String: String],
        range: String?,
        token: String,
        proxyURL: @escaping (URL, String, URL) -> URL?,
        baseURL: URL
    ) {
        self.channel = channel
        self.method = method
        self.originURL = originURL
        self.requestHeaders = headers
        self.range = range
        self.token = token
        self.makeProxyURL = proxyURL
        self.baseURL = baseURL
        self.finalURL = originURL
    }

    func start() {
        var request = URLRequest(url: originURL)
        request.httpMethod = method == .HEAD ? "HEAD" : "GET"
        request.timeoutInterval = 15
        for (name, value) in requestHeaders where !Self.hopByHopHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finishWithError(DLNAProxyError.upstreamUnavailable)
            return
        }
        self.response = http
        finalURL = http.url ?? originURL
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        isPlaylist = originURL.pathExtension.lowercased() == "m3u8" || contentType.localizedCaseInsensitiveContains("mpegurl")
        if !isPlaylist { sendResponseHead(http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isPlaylist {
            playlistData.append(data)
        } else if method != .HEAD {
            write(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error, (error as? URLError)?.code != .cancelled {
            finishWithError(error)
            return
        }
        if isPlaylist {
            guard let response else { finishWithError(DLNAProxyError.upstreamUnavailable); return }
            let rewritten = DLNAHLSPlaylistRewriter.rewrite(
                data: playlistData,
                baseURL: finalURL,
                token: token,
                proxyURL: makeProxyURL,
                proxyBaseURL: baseURL
            )
            sendResponseHead(response, contentLength: rewritten.count)
            if method != .HEAD { write(rewritten) }
        }
        end()
    }

    private func sendResponseHead(_ response: HTTPURLResponse, contentLength: Int? = nil) {
        guard !responseSent else { return }
        responseSent = true
        var headers = NIOHTTP1.HTTPHeaders()
        let allowed = ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Cache-Control", "Expires", "Last-Modified", "ETag"]
        for name in allowed {
            if let value = response.value(forHTTPHeaderField: name) {
                headers.add(name: name, value: value)
            }
        }
        if let contentLength {
            headers.remove(name: "Content-Length")
            headers.add(name: "Content-Length", value: String(contentLength))
            headers.remove(name: "Transfer-Encoding")
        } else if headers.first(name: "Content-Length") == nil {
            headers.add(name: "Transfer-Encoding", value: "chunked")
        }
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
    }

    private func write(_ part: HTTPServerResponsePart) {
        channel.eventLoop.execute { [weak self] in
            guard let self, self.channel.isActive else { return }
            self.channel.writeAndFlush(part, promise: nil)
        }
    }

    private func write(_ data: Data) {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        write(.body(.byteBuffer(buffer)))
    }

    private func end() {
        write(.end(nil))
    }

    private func finishWithError(_ error: Error) {
        guard channel.isActive else { return }
        guard !responseSent else { channel.close(promise: nil); return }
        responseSent = true
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        write(.head(HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)))
        end()
    }

    private static let hopByHopHeaders: Set<String> = ["connection", "host", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]
}

enum DLNAHLSPlaylistRewriter {
    static func rewrite(
        data: Data,
        baseURL: URL,
        token: String,
        proxyURL: (URL, String, URL) -> URL?,
        proxyBaseURL: URL
    ) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.components(separatedBy: .newlines).map { line in
            rewriteLine(line, baseURL: baseURL, token: token, proxyURL: proxyURL, proxyBaseURL: proxyBaseURL)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func rewriteLine(_ line: String, baseURL: URL, token: String, proxyURL: (URL, String, URL) -> URL?, proxyBaseURL: URL) -> String {
        if !line.hasPrefix("#") {
            return proxied(line, baseURL: baseURL, token: token, proxyURL: proxyURL, proxyBaseURL: proxyBaseURL) ?? line
        }
        guard line.contains("URI=") else { return line }
        let pattern = #"URI="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var output = line
        for match in regex.matches(in: line, range: range).reversed() {
            guard let valueRange = Range(match.range(at: 1), in: line) else { continue }
            let raw = String(line[valueRange])
            guard let replacement = proxied(raw, baseURL: baseURL, token: token, proxyURL: proxyURL, proxyBaseURL: proxyBaseURL),
                  let outputRange = Range(match.range(at: 1), in: output) else { continue }
            output.replaceSubrange(outputRange, with: replacement)
        }
        return output
    }

    private static func proxied(_ raw: String, baseURL: URL, token: String, proxyURL: (URL, String, URL) -> URL?, proxyBaseURL: URL) -> String? {
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return proxyURL(url, token, proxyBaseURL)?.absoluteString
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
