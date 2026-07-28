import Foundation
import AngelLiveCore
import CocoaAsyncSocket

public protocol SSDPDiscovering: AnyObject, Sendable {
    func discover(timeout: TimeInterval) async throws -> [[String: String]]
    func cancel()
}

/// Sends a short-lived M-SEARCH and returns only MediaRenderer responses.
public final class SSDPDiscoverer: NSObject, SSDPDiscovering, GCDAsyncUdpSocketDelegate, @unchecked Sendable {
    private static let multicastHost = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900

    private let queue = DispatchQueue(label: "dev.idog.angellive.dlna.ssdp")
    // GCDAsyncUdpSocket can only be bound once, so refresh creates a new socket.
    private var socket: GCDAsyncUdpSocket?
    private var continuation: CheckedContinuation<[[String: String]], Error>?
    private var responses: [[String: String]] = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var isRunning = false

    public override init() {
        super.init()
    }

    public func discover(timeout: TimeInterval = 2.0) async throws -> [[String: String]] {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[[String: String]], Error>) in
                queue.async { [weak self] in
                    self?.start(timeout: timeout, continuation: continuation)
                }
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    public func cancel() {
        queue.async { [weak self] in self?.finish(.failure(DLNAProtocolError.requestCancelled)) }
    }

    private func start(timeout: TimeInterval, continuation: CheckedContinuation<[[String: String]], Error>) {
        finishExistingIfNeeded()
        self.continuation = continuation
        responses.removeAll(keepingCapacity: true)
        isRunning = true

        do {
            let socket = GCDAsyncUdpSocket(delegate: self, delegateQueue: queue)
            self.socket = socket
            socket.setIPv4Enabled(true)
            socket.setIPv6Enabled(false)
            try socket.bind(toPort: 0)
            try socket.beginReceiving()
            socket.send(Self.searchPacket(), toHost: Self.multicastHost, port: Self.multicastPort, withTimeout: timeout, tag: 0)

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finish(.success(self.responses))
            }
            timeoutWorkItem = workItem
            queue.asyncAfter(deadline: .now() + max(0.2, timeout), execute: workItem)
        } catch {
            finish(.failure(error))
        }
    }

    private func finishExistingIfNeeded() {
        guard continuation != nil else { return }
        finish(.failure(DLNAProtocolError.requestCancelled))
    }

    private func finish(_ result: Result<[[String: String]], Error>) {
        guard isRunning || continuation != nil else { return }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        isRunning = false
        socket?.pauseReceiving()
        socket?.close()
        socket = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private static func searchPacket() -> Data {
        let request = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastHost):\(multicastPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 1",
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(request.utf8)
    }

    public func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        guard isRunning else { return }
        let headers = SSDPResponseParser.parse(data)
        guard SSDPResponseParser.isMediaRenderer(headers), headers["location"] != nil else { return }
        if !responses.contains(where: { $0["usn"] == headers["usn"] && $0["location"] == headers["location"] }) {
            responses.append(headers)
        }
    }
}
