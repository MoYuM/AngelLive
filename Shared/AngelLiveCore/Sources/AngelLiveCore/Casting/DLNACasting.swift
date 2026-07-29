import Foundation

/// A discovered UPnP MediaRenderer that exposes the AVTransport service.
public struct DLNADevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let udn: String
    public let friendlyName: String
    public let location: URL
    public let avTransportControlURL: URL
    public let expiresAt: Date

    public init(
        udn: String,
        friendlyName: String,
        location: URL,
        avTransportControlURL: URL,
        expiresAt: Date
    ) {
        self.id = udn
        self.udn = udn
        self.friendlyName = friendlyName
        self.location = location
        self.avTransportControlURL = avTransportControlURL
        self.expiresAt = expiresAt
    }
}

/// The small subset of a device description needed by the first DLNA version.
public struct DLNADeviceDescription: Sendable {
    public let udn: String
    public let friendlyName: String
    public let manufacturer: String?
    public let avTransportControlURL: URL

    public init(
        udn: String,
        friendlyName: String,
        manufacturer: String? = nil,
        avTransportControlURL: URL
    ) {
        self.udn = udn
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.avTransportControlURL = avTransportControlURL
    }
}

public struct DLNAMediaResource: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let mimeType: String
    public let isLive: Bool
    /// Headers the phone-side proxy must add when the renderer fetches this resource.
    public let requestHeaders: [String: String]

    public init(
        url: URL,
        title: String,
        mimeType: String,
        isLive: Bool = true,
        requestHeaders: [String: String] = [:]
    ) {
        self.url = url
        self.title = title
        self.mimeType = mimeType
        self.isLive = isLive
        self.requestHeaders = requestHeaders
    }

    public var requiresLocalProxy: Bool { !requestHeaders.isEmpty }
}

public enum DLNACastCompatibility: Error, Equatable, Sendable {
    case supported
    case invalidURL
    case unsupportedScheme
    case unsupportedStreamFormat
    case requiresRequestHeaders
    case expiredURL

    public var message: String {
        switch self {
        case .supported:
            return ""
        case .invalidURL:
            return "播放地址无效"
        case .unsupportedScheme:
            return "电视只能直接访问 HTTP 或 HTTPS 播放地址"
        case .unsupportedStreamFormat:
            return "该播放源不是可投屏的 HLS、FLV、MPEG-TS 或 MP4 格式"
        case .requiresRequestHeaders:
            return "该播放源需要 Cookie、Referer 或授权请求头，电视无法直接拉流"
        case .expiredURL:
            return "播放地址已过期，请刷新播放源后再投屏"
        }
    }
}

/// Keeps DLNA's stricter source requirements separate from AirPlay's HLS check.
public enum CastCompatibilityEvaluator {
    public static func evaluate(
        url: URL?,
        streamFormat: LivePlaybackStreamFormat,
        headers: [String: String]? = nil,
        userAgent: String? = nil,
        defaultUserAgent: String = "libmpv",
        allowsHeaderDependentSource: Bool = false
    ) -> DLNACastCompatibility {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .invalidURL
        }
        guard scheme == "http" || scheme == "https", url.host != nil else {
            return .unsupportedScheme
        }

        if let expiry = expiryDate(in: url), expiry <= Date() {
            return .expiredURL
        }

        if !allowsHeaderDependentSource {
            let normalizedHeaders = headers ?? [:]
            let forbiddenHeaderNames = ["cookie", "referer", "authorization", "proxy-authorization", "origin"]
            if normalizedHeaders.keys.contains(where: { name in
                forbiddenHeaderNames.contains(name.lowercased())
            }) {
                return .requiresRequestHeaders
            }

            if let headerUserAgent = normalizedHeaders.first(where: { $0.key.caseInsensitiveCompare("user-agent") == .orderedSame })?.value,
               !headerUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               headerUserAgent.trimmingCharacters(in: .whitespacesAndNewlines) != defaultUserAgent {
                return .requiresRequestHeaders
            }

            if let userAgent {
                let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != defaultUserAgent {
                    return .requiresRequestHeaders
                }
            }
        }

        let path = url.path.lowercased()
        let inferredFormat: LivePlaybackStreamFormat?
        if path.hasSuffix(".m3u8") {
            inferredFormat = .hlsLive
        } else if path.hasSuffix(".flv") {
            inferredFormat = .flv
        } else if path.hasSuffix(".mp4") || path.hasSuffix(".m4v") {
            inferredFormat = .hlsVod
        } else if path.hasSuffix(".ts") || path.hasSuffix(".mpeg") || path.hasSuffix(".mpg") {
            inferredFormat = .hlsVod
        } else {
            inferredFormat = nil
        }

        switch streamFormat {
        case .hlsLive, .hlsVod, .flv:
            return .supported
        case .dash:
            return .unsupportedStreamFormat
        case .unknown:
            return inferredFormat == nil ? .unsupportedStreamFormat : .supported
        }
    }

    public static func resource(
        url: URL?,
        title: String,
        streamFormat: LivePlaybackStreamFormat,
        isLive: Bool = true,
        headers: [String: String]? = nil,
        userAgent: String? = nil,
        allowsHeaderDependentSource: Bool = false
    ) -> Result<DLNAMediaResource, DLNACastCompatibility> {
        let compatibility = evaluate(
            url: url,
            streamFormat: streamFormat,
            headers: headers,
            userAgent: userAgent,
            allowsHeaderDependentSource: allowsHeaderDependentSource
        )
        guard compatibility == .supported, let url else {
            return .failure(compatibility)
        }

        let mimeType: String
        switch streamFormat {
        case .hlsLive, .hlsVod:
            mimeType = "application/vnd.apple.mpegurl"
        case .flv:
            mimeType = "video/x-flv"
        case .unknown:
            let path = url.path.lowercased()
            if path.hasSuffix(".m3u8") {
                mimeType = "application/vnd.apple.mpegurl"
            } else if path.hasSuffix(".flv") {
                mimeType = "video/x-flv"
            } else if path.hasSuffix(".mp4") || path.hasSuffix(".m4v") {
                mimeType = "video/mp4"
            } else {
                mimeType = "video/mp2t"
            }
        case .dash:
            return .failure(.unsupportedStreamFormat)
        }
        var proxyHeaders = headers ?? [:]
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasUserAgent = proxyHeaders.keys.contains {
                $0.caseInsensitiveCompare("user-agent") == .orderedSame
            }
            if !trimmed.isEmpty, !hasUserAgent {
                proxyHeaders["User-Agent"] = trimmed
            }
        }
        proxyHeaders = proxyHeaders.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return .success(DLNAMediaResource(
            url: url,
            title: title,
            mimeType: mimeType,
            isLive: isLive,
            requestHeaders: proxyHeaders
        ))
    }

    private static func expiryDate(in url: URL) -> Date? {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let keys = Set(["expires", "expire", "expires_at", "exp", "end"])
        guard let value = query.first(where: { keys.contains($0.name.lowercased()) })?.value,
              let raw = Double(value) else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        // Ignore values that are clearly not Unix timestamps; some platforms use
        // these names for opaque token versions rather than an expiry time.
        guard seconds >= 100_000_000 && seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

public enum SSDPResponseParser {
    public static func parse(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: .newlines).dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, headers[key] == nil {
                headers[key] = value
            }
        }
        return headers
    }

    public static func isMediaRenderer(_ headers: [String: String]) -> Bool {
        let searchTarget = (headers["st"] ?? "") + " " + (headers["usn"] ?? "")
        return searchTarget.localizedCaseInsensitiveContains("mediarenderer")
    }
}

public enum DLNADeviceDescriptionParser {
    public static func parse(data: Data, location: URL) throws -> DLNADeviceDescription {
        let delegate = Delegate(location: location)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DLNAProtocolError.invalidDeviceDescription(parser.parserError?.localizedDescription ?? "XML 解析失败")
        }
        return try delegate.result()
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let location: URL
        var currentElement = ""
        var currentValue = ""
        var udn: String?
        var friendlyName: String?
        var manufacturer: String?
        var avTransportControlURL: URL?
        var serviceType: String?

        init(location: URL) { self.location = location }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            currentValue = ""
            if elementName.caseInsensitiveCompare("service") == .orderedSame {
                serviceType = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentValue += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName.lowercased() {
            case "udn": if !value.isEmpty { udn = value }
            case "friendlyname": if !value.isEmpty { friendlyName = value }
            case "manufacturer": if !value.isEmpty { manufacturer = value }
            case "servicetype": serviceType = value
            case "controlurl":
                if serviceType?.localizedCaseInsensitiveContains("avtransport") == true,
                   let url = URL(string: value, relativeTo: location)?.absoluteURL {
                    avTransportControlURL = url
                }
            default: break
            }
            currentElement = ""
            currentValue = ""
        }

        func result() throws -> DLNADeviceDescription {
            guard let udn, !udn.isEmpty else { throw DLNAProtocolError.invalidDeviceDescription("缺少 UDN") }
            guard let friendlyName, !friendlyName.isEmpty else { throw DLNAProtocolError.invalidDeviceDescription("缺少设备名称") }
            guard let avTransportControlURL else { throw DLNAProtocolError.avTransportUnavailable }
            return DLNADeviceDescription(udn: udn, friendlyName: friendlyName, manufacturer: manufacturer, avTransportControlURL: avTransportControlURL)
        }
    }
}

public enum DLNAProtocolError: Error, LocalizedError, Sendable, Equatable {
    case invalidDeviceDescription(String)
    case avTransportUnavailable
    case invalidResponse
    case httpStatus(Int)
    case soapFault(String)
    case timeout
    case deviceOffline
    case noDevices
    case requestCancelled

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceDescription(let reason): return "设备描述无效：\(reason)"
        case .avTransportUnavailable: return "设备不支持 AVTransport"
        case .invalidResponse: return "设备返回了无法识别的响应"
        case .httpStatus(let code): return "设备请求失败（HTTP \(code)）"
        case .soapFault(let reason): return "设备拒绝了投屏请求：\(reason)"
        case .timeout: return "连接设备超时"
        case .deviceOffline: return "无法连接到设备，请确认电视仍在同一个 Wi‑Fi 网络"
        case .noDevices: return "未发现局域网内的 DLNA 设备"
        case .requestCancelled: return "投屏请求已取消"
        }
    }
}
