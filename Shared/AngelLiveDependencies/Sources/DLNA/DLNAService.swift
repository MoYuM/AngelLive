import Foundation
import AngelLiveCore

public final class DLNAService: @unchecked Sendable {
    private let session: URLSession
    private let discoverer: any SSDPDiscovering

    public init(session: URLSession = .shared, discoverer: any SSDPDiscovering = SSDPDiscoverer()) {
        self.session = session
        self.discoverer = discoverer
    }

    public func discoverDevices(timeout: TimeInterval = 2.0) async throws -> [DLNADevice] {
        let responses = try await discoverer.discover(timeout: timeout)
        guard !responses.isEmpty else { throw DLNAProtocolError.noDevices }

        var devices: [String: DLNADevice] = [:]
        for response in responses {
            guard let locationString = response["location"],
                  let location = URL(string: locationString) else { continue }

            let data: Data
            do {
                data = try await loadDescription(from: location)
            } catch is CancellationError {
                throw CancellationError()
            } catch DLNAProtocolError.requestCancelled {
                throw DLNAProtocolError.requestCancelled
            } catch {
                continue
            }

            let description: DLNADeviceDescription
            do {
                description = try DLNADeviceDescriptionParser.parse(data: data, location: location)
            } catch {
                continue
            }

            let maxAge = Self.maxAge(from: response["cache-control"]) ?? 1800
            let device = DLNADevice(
                udn: description.udn,
                friendlyName: description.friendlyName,
                location: location,
                avTransportControlURL: description.avTransportControlURL,
                expiresAt: Date().addingTimeInterval(maxAge)
            )
            devices[device.udn] = device
        }

        guard !devices.isEmpty else { throw DLNAProtocolError.noDevices }
        return devices.values.sorted { $0.friendlyName.localizedStandardCompare($1.friendlyName) == .orderedAscending }
    }

    public func stopDiscovery() {
        discoverer.cancel()
    }

    private func loadDescription(from location: URL) async throws -> Data {
        var request = URLRequest(url: location)
        request.timeoutInterval = 4
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapNetworkError(error)
        }
        guard let response = response as? HTTPURLResponse else { throw DLNAProtocolError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw DLNAProtocolError.httpStatus(response.statusCode) }
        return data
    }

    fileprivate static func mapNetworkError(_ error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .timedOut:
            return DLNAProtocolError.timeout
        case .cancelled:
            return DLNAProtocolError.requestCancelled
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
            return DLNAProtocolError.deviceOffline
        default:
            return error
        }
    }

    private static func maxAge(from cacheControl: String?) -> TimeInterval? {
        guard let cacheControl else { return nil }
        let components = cacheControl.split(separator: ",")
        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].caseInsensitiveCompare("max-age") == .orderedSame,
                  let seconds = TimeInterval(parts[1]) else { continue }
            return max(0, seconds)
        }
        return nil
    }
}

public final class DLNAAVTransportClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func setAVTransportURI(device: DLNADevice, resource: DLNAMediaResource) async throws {
        _ = try await send(
            action: "SetAVTransportURI",
            controlURL: device.avTransportControlURL,
            arguments: [
                "InstanceID": "0",
                "CurrentURI": resource.url.absoluteString,
                "CurrentURIMetaData": Self.metadata(for: resource)
            ]
        )
    }

    public func play(device: DLNADevice) async throws {
        _ = try await send(
            action: "Play",
            controlURL: device.avTransportControlURL,
            arguments: ["InstanceID": "0", "Speed": "1"]
        )
    }

    public func stop(device: DLNADevice) async throws {
        _ = try await send(
            action: "Stop",
            controlURL: device.avTransportControlURL,
            arguments: ["InstanceID": "0"]
        )
    }

    public func transportState(device: DLNADevice) async throws -> String {
        let body = try await send(
            action: "GetTransportInfo",
            controlURL: device.avTransportControlURL,
            arguments: ["InstanceID": "0"]
        )
        guard let range = body.range(of: "<CurrentTransportState>"),
              let end = body.range(of: "</CurrentTransportState>", range: range.upperBound..<body.endIndex)
        else { throw DLNAProtocolError.invalidResponse }
        return String(body[range.upperBound..<end.lowerBound])
    }

    private func send(action: String, controlURL: URL, arguments: [String: String]) async throws -> String {
        let serviceType = "urn:schemas-upnp-org:service:AVTransport:1"
        let argumentXML = arguments.map { "<\($0.key)>\(Self.escapeXML($0.value))</\($0.key)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:\(action) xmlns:u="\(serviceType)">\(argumentXML)</u:\(action)></s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DLNAService.mapNetworkError(error)
        }
        guard let response = response as? HTTPURLResponse else { throw DLNAProtocolError.invalidResponse }
        let body = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.soapFault(from: body) ?? DLNAProtocolError.httpStatus(response.statusCode)
        }
        if let fault = Self.soapFault(from: body) { throw fault }
        return body
    }

    private static func metadata(for resource: DLNAMediaResource) -> String {
        let escapedTitle = escapeXML(resource.title)
        let escapedURL = escapeXML(resource.url.absoluteString)
        let protocolInfo = "http-get:*:\(resource.mimeType):*"
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>\(escapedTitle)</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"\(protocolInfo)\">\(escapedURL)</res></item></DIDL-Lite>"
    }

    private static func soapFault(from body: String) -> DLNAProtocolError? {
        if let start = body.range(of: "<errorDescription>"),
           let end = body.range(of: "</errorDescription>", range: start.upperBound..<body.endIndex) {
            return .soapFault(String(body[start.upperBound..<end.lowerBound]))
        }
        guard body.localizedCaseInsensitiveContains("<s:fault") || body.localizedCaseInsensitiveContains("<soap:fault") else {
            return nil
        }
        if let start = body.range(of: "<faultstring>"),
           let end = body.range(of: "</faultstring>", range: start.upperBound..<body.endIndex) {
            return .soapFault(String(body[start.upperBound..<end.lowerBound]))
        }
        return .soapFault("SOAP Fault")
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
