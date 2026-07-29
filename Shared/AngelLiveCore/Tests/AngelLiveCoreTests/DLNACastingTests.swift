import Foundation
import Testing
@testable import AngelLiveCore

@Suite("DLNA casting policy and parser")
struct DLNACastingTests {
    @Test("public HLS without extra headers is compatible")
    func publicHLSIsCompatible() {
        let url = URL(string: "https://cdn.example.com/live/index.m3u8?token=abc")
        #expect(CastCompatibilityEvaluator.evaluate(url: url, streamFormat: .hlsLive) == .supported)
    }

    @Test("unknown stream format infers HLS metadata from the URL")
    func unknownHLSResourceUsesHLSMIMEType() {
        let url = URL(string: "https://cdn.example.com/live/index.m3u8")
        let resource = try? CastCompatibilityEvaluator.resource(
            url: url,
            title: "Test Stream",
            streamFormat: .unknown
        ).get()

        #expect(resource?.mimeType == "application/vnd.apple.mpegurl")
    }

    @Test("expired query token is rejected before casting")
    func expiredTokenIsRejected() {
        let url = URL(string: "https://cdn.example.com/live.m3u8?expires=1000000000")
        #expect(CastCompatibilityEvaluator.evaluate(url: url, streamFormat: .hlsLive) == .expiredURL)
    }

    @Test("cookie and referer sources are rejected")
    func requestHeadersAreRejected() {
        let url = URL(string: "https://cdn.example.com/live.m3u8")
        #expect(CastCompatibilityEvaluator.evaluate(url: url, streamFormat: .hlsLive, headers: ["Referer": "https://example.com"]) == .requiresRequestHeaders)
        #expect(CastCompatibilityEvaluator.evaluate(url: url, streamFormat: .hlsLive, headers: ["cookie": "sid=secret"]) == .requiresRequestHeaders)
        #expect(CastCompatibilityEvaluator.evaluate(url: url, streamFormat: .hlsLive, headers: ["User-Agent": "Mozilla/5.0"]) == .requiresRequestHeaders)
    }

    @Test("FLV streams are compatible and use FLV metadata")
    func flvIsCompatible() {
        let url = URL(string: "https://cdn.example.com/live.flv?token=abc")
        #expect(CastCompatibilityEvaluator.evaluate(url: url, streamFormat: .flv) == .supported)

        let explicitResource = try? CastCompatibilityEvaluator.resource(
            url: url,
            title: "FLV Stream",
            streamFormat: .flv
        ).get()
        let inferredResource = try? CastCompatibilityEvaluator.resource(
            url: url,
            title: "FLV Stream",
            streamFormat: .unknown
        ).get()

        #expect(explicitResource?.mimeType == "video/x-flv")
        #expect(inferredResource?.mimeType == "video/x-flv")
    }

    @Test("FLV can opt in to casting even when the source declares request headers")
    func flvCanBypassRequestHeaderGate() {
        let url = URL(string: "https://cdn.example.com/live.flv")
        let headers = ["Referer": "https://www.example.com"]

        #expect(
            CastCompatibilityEvaluator.evaluate(
                url: url,
                streamFormat: .flv,
                headers: headers
            ) == .requiresRequestHeaders
        )
        #expect(
            CastCompatibilityEvaluator.evaluate(
                url: url,
                streamFormat: .flv,
                headers: headers,
                userAgent: "Mozilla/5.0",
                allowsHeaderDependentSource: true
            ) == .supported
        )

        let resource = try? CastCompatibilityEvaluator.resource(
            url: url,
            title: "FLV Stream",
            streamFormat: .flv,
            headers: headers,
            userAgent: "Mozilla/5.0",
            allowsHeaderDependentSource: true
        ).get()
        #expect(resource?.mimeType == "video/x-flv")
        #expect(resource?.requestHeaders["Referer"] == "https://www.example.com")
        #expect(resource?.requestHeaders["User-Agent"] == "Mozilla/5.0")
    }

    @Test("custom user agent is retained for the phone-side DLNA proxy")
    func customUserAgentIsRetainedForProxy() throws {
        let resource = try CastCompatibilityEvaluator.resource(
            url: URL(string: "https://cdn.example.com/live.m3u8"),
            title: "HLS Stream",
            streamFormat: .hlsLive,
            userAgent: "CustomTVUA/1.0",
            allowsHeaderDependentSource: true
        ).get()

        #expect(resource.requiresLocalProxy)
        #expect(resource.requestHeaders["User-Agent"] == "CustomTVUA/1.0")
    }

    @Test("DASH and non HTTP URLs are rejected")
    func unsupportedSourcesAreRejected() {
        #expect(CastCompatibilityEvaluator.evaluate(url: URL(string: "https://cdn.example.com/manifest.mpd"), streamFormat: .dash) == .unsupportedStreamFormat)
        #expect(CastCompatibilityEvaluator.evaluate(url: URL(string: "file:///tmp/live.m3u8"), streamFormat: .hlsLive) == .unsupportedScheme)
    }

    @Test("device description resolves relative AVTransport URL")
    func parsesDeviceDescription() throws {
        let xml = """
        <root><device><friendlyName>Living Room TV</friendlyName><manufacturer>Example</manufacturer><UDN>uuid:tv-1</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/render</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/upnp/control/av</controlURL></service></serviceList></device></root>
        """
        let location = try #require(URL(string: "http://192.168.1.10:8008/device.xml"))
        let description = try DLNADeviceDescriptionParser.parse(data: Data(xml.utf8), location: location)

        #expect(description.udn == "uuid:tv-1")
        #expect(description.friendlyName == "Living Room TV")
        #expect(description.avTransportControlURL.absoluteString == "http://192.168.1.10:8008/upnp/control/av")
    }

    @Test("SSDP parser normalizes header names and filters renderers")
    func parsesSSDPResponse() {
        let response = """
        HTTP/1.1 200 OK\r
        LOCATION: http://192.168.1.10:8008/device.xml\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        USN: uuid:tv-1::urn:schemas-upnp-org:device:MediaRenderer:1\r
        \r
        """
        let headers = SSDPResponseParser.parse(response)
        #expect(headers["location"] == "http://192.168.1.10:8008/device.xml")
        #expect(SSDPResponseParser.isMediaRenderer(headers))
    }
}
