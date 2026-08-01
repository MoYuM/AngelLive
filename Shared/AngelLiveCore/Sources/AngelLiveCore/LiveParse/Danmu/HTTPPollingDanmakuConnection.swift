import Foundation
@preconcurrency import Alamofire

/// 与 `WebSocketConnection` 同构:轮询 Timer 落在主 runloop,delegate 是 UI 层,
/// 状态(isConnected / isRequestInFlight / pollingTimer 等)本就只在主线程读写。
/// 标注 `@MainActor` 把这份既有约定交给编译器保证。
@MainActor
public final class HTTPPollingDanmakuConnection {
    public var parameters: [String: String]?
    var headers: [String: String]?
    public weak var delegate: WebSocketConnectionDelegate?

    let liveType: LiveType

    private let danmakuPlan: LiveParseDanmakuPlan?
    private let pluginId: String?
    private var pluginDriver: PluginJSDanmakuDriver?
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 3.0
    private var pollingURL: String = ""
    private var pollingMethod: String = "POST"
    private var isConnected = false
    private var isRequestInFlight = false
    private var driverTimerReason: PluginJSDanmakuDriver.TickReason = .polling

    public init(parameters: [String: String]?, headers: [String: String]?, liveType: LiveType) {
        self.parameters = parameters
        self.headers = headers
        self.liveType = liveType
        self.danmakuPlan = nil
        self.pluginId = nil
        parseConfig()
    }

    public init(
        parameters: [String: String]?,
        headers: [String: String]?,
        liveType: LiveType,
        pluginId: String,
        roomId: String,
        userId: String?,
        danmakuPlan: LiveParseDanmakuPlan
    ) {
        self.parameters = parameters
        self.headers = headers
        self.liveType = liveType
        self.danmakuPlan = danmakuPlan
        self.pluginId = pluginId

        if danmakuPlan.usesPluginRuntimeDriver {
            self.pluginDriver = PluginJSDanmakuDriver(
                pluginId: pluginId,
                roomId: roomId,
                userId: userId,
                plan: danmakuPlan
            )
        }

        parseConfig()
    }

    /// `isolated deinit`:在主 actor 上执行析构,理由同 `WebSocketConnection`——
    /// nonisolated deinit 无法访问非 Sendable 的 `pollingTimer`,也就复用不了 `disconnect()`。
    isolated deinit {
        Task { [pluginDriver] in
            await pluginDriver?.destroy(reason: .deinitialized)
        }
        disconnect()
    }

    public func connect() {
        guard let pluginDriver else {
            delegate?.webSocketDidDisconnect(
                error: LiveParseError.danmuArgsParseError("弹幕驱动不受支持", "插件未声明 runtime.driver=plugin_js_v1：\(liveType.rawValue)")
            )
            return
        }

        guard !pollingURL.isEmpty else {
            delegate?.webSocketDidDisconnect(
                error: LiveParseError.danmuArgsParseError("弹幕轮询地址缺失", "插件未返回可用的 transport.url / _polling_url")
            )
            return
        }

        isConnected = true
        isRequestInFlight = false
        delegate?.webSocketDidConnect()

        Task {
            do {
                let result = try await pluginDriver.createSession()
                applyDriverResult(result)

                let shouldSendOnConnect = danmakuPlan?.transport?.polling?.sendOnConnect ?? true
                if shouldSendOnConnect {
                    if let poll = result.poll {
                        executePoll(poll)
                    } else {
                        runDriverTick()
                    }
                }
            } catch {
                handleDriverFailure(error)
            }
        }
    }

    public func disconnect() {
        stopPollingTimer()
        isConnected = false
        isRequestInFlight = false
        Task { [pluginDriver] in
            await pluginDriver?.destroy(reason: .disconnect)
        }
    }
}

private extension HTTPPollingDanmakuConnection {
    func parseConfig() {
        if let url = danmakuPlan?.transport?.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            pollingURL = url
        } else if let url = parameters?["_polling_url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            pollingURL = url
        }

        if let method = danmakuPlan?.transport?.polling?.method?.trimmingCharacters(in: .whitespacesAndNewlines), !method.isEmpty {
            pollingMethod = method.uppercased()
        } else if let method = parameters?["_polling_method"]?.trimmingCharacters(in: .whitespacesAndNewlines), !method.isEmpty {
            pollingMethod = method.uppercased()
        }

        if let intervalMs = danmakuPlan?.transport?.polling?.intervalMs {
            pollingInterval = max(Double(intervalMs) / 1000.0, 1.0)
        } else if let intervalText = parameters?["_polling_interval"], let intervalMs = Double(intervalText) {
            pollingInterval = max(intervalMs / 1000.0, 1.0)
        }
    }

    func startPollingTimer() {
        stopPollingTimer()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            // Timer 下面即被加进 RunLoop.current(主 runloop),回调必在主线程。
            MainActor.assumeIsolated {
                self?.runDriverTick()
            }
        }
        if let pollingTimer {
            RunLoop.current.add(pollingTimer, forMode: .common)
        }
    }

    func stopPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func runDriverTick() {
        guard let pluginDriver, isConnected, !isRequestInFlight else { return }

        Task {
            do {
                let result = try await pluginDriver.onTick(reason: driverTimerReason)
                applyDriverResult(result)
                if let poll = result.poll {
                    executePoll(poll)
                }
            } catch {
                handleDriverFailure(error)
            }
        }
    }

    func applyDriverResult(_ result: LiveParseDanmakuDriverResult) {
        deliverMessages(result.messages)
        updateTimer(result.timer)
    }

    func deliverMessages(_ messages: [LiveParseDanmakuMessage]?) {
        guard let messages else { return }
        for message in messages {
            delegate?.webSocketDidReceiveMessage(
                text: message.text,
                nickname: message.nickname,
                color: message.color ?? 0xFFFFFF
            )
        }
    }

    func updateTimer(_ timer: LiveParseDanmakuTimerPlan?) {
        guard let timer else { return }

        switch timer.mode {
        case .off:
            stopPollingTimer()
            return
        case .heartbeat:
            driverTimerReason = .heartbeat
        case .polling:
            driverTimerReason = .polling
        }

        pollingInterval = max(Double(timer.intervalMs ?? 0) / 1000.0, 1.0)
        startPollingTimer()
    }

    func executePoll(_ poll: LiveParseDanmakuPollRequest) {
        guard isConnected, !isRequestInFlight else { return }
        guard let request = makeRequest(from: poll) else {
            handleDriverFailure(
                LiveParseError.danmuArgsParseError("弹幕轮询请求无效", "插件返回的轮询请求缺少可用 URL")
            )
            return
        }

        isRequestInFlight = true
        AF.request(request).responseData { [weak self] response in
            // Alamofire 的 responseData 默认 `queue: DispatchQueue = .main`,此处未覆盖,
            // 故回调必在主线程,直接复用主 actor 隔离即可,无需再跳一次。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRequestInFlight = false

                switch response.result {
                case .success(let data):
                    self.handleHTTPResponse(data: data, response: response.response)
                case .failure(let error):
                    self.handleDriverFailure(error)
                }
            }
        }
    }

    func makeRequest(from poll: LiveParseDanmakuPollRequest) -> URLRequest? {
        let normalizedURL = poll.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLText = (normalizedURL?.isEmpty == false) ? normalizedURL! : pollingURL
        guard !baseURLText.isEmpty else { return nil }

        var components = URLComponents(string: baseURLText)
        if let query = poll.query, !query.isEmpty {
            var queryItems = components?.queryItems ?? []
            for (key, value) in query {
                queryItems.removeAll { $0.name == key }
                queryItems.append(URLQueryItem(name: key, value: value))
            }
            components?.queryItems = queryItems
        }

        var mergedHeaders = headers ?? [:]
        if let pollHeaders = poll.headers {
            for (key, value) in pollHeaders {
                mergedHeaders[key] = value
            }
        }

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        let method = poll.method?.trimmingCharacters(in: .whitespacesAndNewlines)
        request.httpMethod = ((method?.isEmpty == false) ? method : pollingMethod)?.uppercased()

        for (key, value) in mergedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let bodyText = poll.bodyText {
            request.httpBody = bodyText.data(using: .utf8)
        } else if let bodyBase64 = poll.bodyBase64 {
            request.httpBody = Data(base64Encoded: bodyBase64)
        }

        return request
    }

    func handleHTTPResponse(data: Data, response: HTTPURLResponse?) {
        guard let pluginDriver else {
            handleDriverFailure(
                LiveParseError.danmuArgsParseError("弹幕驱动不受支持", "插件驱动在处理轮询响应时丢失")
            )
            return
        }

        let responseHeaders = response?.allHeaderFields.reduce(into: [String: String]()) { partialResult, item in
            if let key = item.key as? String {
                partialResult[key] = String(describing: item.value)
            }
        } ?? [:]

        let textBody = String(data: data, encoding: .utf8)

        Task {
            do {
                let result = try await pluginDriver.onFrame(
                    frameType: .httpResponse,
                    text: textBody,
                    data: textBody == nil ? data : nil,
                    statusCode: response?.statusCode,
                    responseHeaders: responseHeaders
                )
                applyDriverResult(result)
                if let poll = result.poll {
                    executePoll(poll)
                }
            } catch {
                handleDriverFailure(error)
            }
        }
    }

    func handleDriverFailure(_ error: Error) {
        stopPollingTimer()
        isConnected = false
        isRequestInFlight = false
        delegate?.webSocketDidDisconnect(error: error)
        Task { [pluginDriver] in
            await pluginDriver?.destroy(reason: .error)
        }
    }
}
