import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import AngelLiveCore
@testable import AngelLiveDependencies

@Suite("DLNA network fixtures", .serialized)
struct DLNANetworkTests {
    @Test("SSDP response and device description are discovered from fixtures")
    func discoversFixtureDevice() async throws {
        let location = try #require(URL(string: "http://192.168.1.40:8008/device.xml"))
        let ssdpHeaders = SSDPResponseParser.parse(try fixture(named: "ssdp_media_renderer", fileExtension: "txt"))
        let discoverer = StubSSDPDiscoverer(responses: [ssdpHeaders])
        let session = makeSession { request in
            #expect(request.url == location)
            return .success(statusCode: 200, data: try fixture(named: "device"))
        }
        let service = DLNAService(session: session, discoverer: discoverer)

        let devices = try await service.discoverDevices(timeout: 0.1)

        #expect(devices.count == 1)
        #expect(devices[0].udn == "uuid:fixture-tv-1")
        #expect(devices[0].friendlyName == "Fixture Living Room TV")
        #expect(devices[0].avTransportControlURL.absoluteString == "http://192.168.1.40:8008/upnp/control/avtransport")
        #expect(devices[0].expiresAt.timeIntervalSinceNow > 50)
    }

    @Test("AVTransport sends SOAP actions and parses transport state")
    func sendsSOAPActions() async throws {
        let requests = RequestRecorder()
        let session = makeSession { request in
            requests.append(request)
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetTransportInfo") {
                return .success(statusCode: 200, data: try fixture(named: "soap_transport_info"))
            }
            return .success(statusCode: 200, data: try fixture(named: "soap_success"))
        }
        let device = try makeDevice()
        let resource = DLNAMediaResource(
            url: try #require(URL(string: "https://cdn.example.com/live.m3u8?token=a&b=c")),
            title: "测试 & 直播",
            mimeType: "application/vnd.apple.mpegurl"
        )
        let client = DLNAAVTransportClient(session: session)

        try await client.setAVTransportURI(device: device, resource: resource)
        try await client.play(device: device)
        let state = try await client.transportState(device: device)
        try await client.stop(device: device)

        #expect(state == "PLAYING")
        let bodies = requests.allBodies().map { String(decoding: $0, as: UTF8.self) }
        #expect(bodies.count == 4)
        guard bodies.count == 4 else { return }
        #expect(bodies[0].contains("测试 &amp;amp; 直播"))
        #expect(bodies[0].contains("token=a&amp;amp;b=c"))
        #expect(bodies[1].contains("<u:Play"))
        #expect(bodies[2].contains("<u:GetTransportInfo"))
        #expect(bodies[3].contains("<u:Stop"))
    }

    @Test("SOAP Fault is surfaced with the device error description")
    func surfacesSOAPFault() async throws {
        let session = makeSession { _ in
            .success(statusCode: 500, data: try fixture(named: "soap_fault"))
        }
        let client = DLNAAVTransportClient(session: session)
        let device = try makeDevice()

        do {
            try await client.play(device: device)
            Issue.record("Expected Play to fail with a SOAP Fault")
        } catch let error as DLNAProtocolError {
            #expect(error == .soapFault("Transition not available"))
        }
    }

    @Test("HTTP timeout is mapped to a user-facing DLNA timeout")
    func mapsHTTPTimeout() async throws {
        let session = makeSession { _ in .failure(URLError(.timedOut)) }
        let client = DLNAAVTransportClient(session: session)
        let device = try makeDevice()

        do {
            try await client.stop(device: device)
            Issue.record("Expected Stop to time out")
        } catch let error as DLNAProtocolError {
            #expect(error == .timeout)
        }
    }

    @Test("offline HTTP connection is surfaced separately from a timeout")
    func mapsOfflineConnection() async throws {
        let session = makeSession { _ in .failure(URLError(.cannotConnectToHost)) }
        let client = DLNAAVTransportClient(session: session)
        let device = try makeDevice()

        do {
            try await client.stop(device: device)
            Issue.record("Expected Stop to report the device as offline")
        } catch let error as DLNAProtocolError {
            #expect(error == .deviceOffline)
        }
    }

    @Test("HLS proxy rewrites playlists, segments, and URI attributes")
    func rewritesHLSResourcesThroughProxy() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1280000
        low/index.m3u8
        #EXT-X-KEY:METHOD=AES-128,URI="keys/live.key"
        #EXT-X-MAP:URI="https://media.example.net/init.mp4"
        segment0001.ts?token=abc
        """
        let baseURL = try #require(URL(string: "https://cdn.example.com/live/master.m3u8"))
        let proxyBaseURL = try #require(URL(string: "http://192.168.1.20:49152"))

        let rewritten = DLNAHLSPlaylistRewriter.rewrite(
            data: Data(playlist.utf8),
            baseURL: baseURL,
            token: "session-token",
            proxyURL: { origin, token, baseURL in
                baseURL.appendingPathComponent(token).appendingPathComponent(origin.lastPathComponent)
            },
            proxyBaseURL: proxyBaseURL
        )
        let output = String(decoding: rewritten, as: UTF8.self)

        #expect(output.contains("http://192.168.1.20:49152/session-token/index.m3u8"))
        #expect(output.contains("URI=\"http://192.168.1.20:49152/session-token/live.key\""))
        #expect(output.contains("URI=\"http://192.168.1.20:49152/session-token/init.mp4\""))
        #expect(output.contains("http://192.168.1.20:49152/session-token/segment0001.ts"))
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> MockURLProtocol.Result
    ) -> URLSession {
        MockURLProtocol.install(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeDevice() throws -> DLNADevice {
        DLNADevice(
            udn: "uuid:fixture-tv-1",
            friendlyName: "Fixture TV",
            location: try #require(URL(string: "http://192.168.1.40:8008/device.xml")),
            avTransportControlURL: try #require(URL(string: "http://192.168.1.40:8008/upnp/control/avtransport")),
            expiresAt: .distantFuture
        )
    }

    private func fixture(named name: String, fileExtension: String = "xml") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: fileExtension))
        return try Data(contentsOf: url)
    }
}

private final class StubSSDPDiscoverer: SSDPDiscovering, @unchecked Sendable {
    let responses: [[String: String]]

    init(responses: [[String: String]]) {
        self.responses = responses
    }

    func discover(timeout: TimeInterval) async throws -> [[String: String]] {
        responses
    }

    func cancel() {}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    func append(_ request: URLRequest) {
        lock.lock()
        if let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream) {
            bodies.append(body)
        }
        lock.unlock()
    }

    func allBodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class MockURLProtocol: URLProtocol {
    struct Result {
        let statusCode: Int
        let data: Data
        let error: Error?

        static func success(statusCode: Int, data: Data) -> Result {
            Result(statusCode: statusCode, data: data, error: nil)
        }

        static func failure(_ error: Error) -> Result {
            Result(statusCode: 0, data: Data(), error: error)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> Result)?

    static func install(handler: @escaping (URLRequest) throws -> Result) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result: Result
        do {
            Self.lock.lock()
            let currentHandler = Self.handler
            Self.lock.unlock()
            guard let currentHandler else { throw URLError(.badServerResponse) }
            result = try currentHandler(request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let error = result.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: result.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/xml"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
