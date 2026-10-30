import Foundation

/// Builds the `ws://` or `wss://` address of a BBS's WebSocket.
public enum WebSocketEndpoint {
    /// The default port (80, or 443 with TLS) is left out of the URL; an IPv6 host is bracketed.
    public static func url(host: String, port: Int, path: String, secure: Bool) -> URL? {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        let scheme = secure ? "wss" : "ws"
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let shownPort = port == ConnectionMode.webSocket.defaultPort(secure: secure) ? "" : ":\(port)"
        var shownPath = path.trimmingCharacters(in: .whitespaces)
        if !shownPath.hasPrefix("/") { shownPath = "/" + shownPath }
        return URL(string: "\(scheme)://\(shownHost)\(shownPort)\(shownPath)")
    }
}

/// A WebSocket to a BBS (`URLSessionWebSocketTask`, no dependency). Sends binary frames; passes
/// on binary frames unchanged and text frames as their UTF-8 bytes. TLS (wss) uses the system's
/// certificate trust.
public final class WebSocketTransport: NSObject, BBSTransport, URLSessionWebSocketDelegate {
    public var events: ((TransportEvent) -> Void)?
    public let host: String
    public let port: Int
    public let settings: TransportSettings
    public let connectTimeout: TimeInterval
    public let queue: DispatchQueue

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opened = false
    private var done = false

    public init(host: String, port: Int, settings: TransportSettings, connectTimeout: TimeInterval, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.settings = settings
        self.connectTimeout = connectTimeout
        self.queue = queue
    }

    public func open() {
        guard task == nil, !done else { return }
        guard let url = WebSocketEndpoint.url(host: host, port: port, path: settings.webSocketPath,
                                              secure: settings.webSocketSecure) else {
            finish(.other("\"\(host)\" with path \"\(settings.webSocketPath)\" is not a valid WebSocket address."))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        // The client's own timer limits the handshake; an open WebSocket may stay silent for hours
        // (a BBS waiting at a prompt), so URLSession's idle timeout is set out of the way.
        configuration.timeoutIntervalForRequest = 7 * 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let protocols = settings.webSocketSubprotocols
        let task = protocols.isEmpty ? session.webSocketTask(with: url) : session.webSocketTask(with: url, protocols: protocols)
        self.session = session
        self.task = task
        task.resume()
    }

    public func write(_ bytes: [UInt8]) {
        guard let task, opened, !done, !bytes.isEmpty else { return }
        task.send(.data(Data(bytes))) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.fail(error, task: task) }
        }
    }

    public func resize(columns: Int, rows: Int) {}

    public func close() {
        guard !done else { return }
        done = true
        task?.cancel(with: .normalClosure, reason: nil)
        // The session keeps its delegate (this object) until it is invalidated.
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    /// The bytes of a received message: binary unchanged, text as UTF-8.
    public static func bytes(of message: URLSessionWebSocketTask.Message) -> [UInt8] {
        switch message {
        case .data(let data): return Array(data)
        case .string(let text): return Array(text.utf8)
        @unknown default: return []
        }
    }

    /// A URLSession failure in plain words: TLS, an HTTP answer instead of an upgrade, DNS, refused.
    public static func map(_ error: Error, response: URLResponse?, host: String, port: Int,
                           connected: Bool) -> BBSConnectionError {
        let code = (error as? URLError)?.code
        switch code {
        case .serverCertificateUntrusted?, .serverCertificateHasUnknownRoot?:
            return .tls(host, "the server's certificate is not trusted by this Mac (it may be self signed).")
        case .serverCertificateHasBadDate?, .serverCertificateNotYetValid?:
            return .tls(host, "the server's certificate has expired or is not valid yet.")
        case .clientCertificateRejected?, .clientCertificateRequired?:
            return .tls(host, "the server wants a client certificate, which AnsiView does not offer.")
        case .secureConnectionFailed?:
            return .tls(host, "the server did not complete a secure handshake; it may not offer wss on this port.")
        default: break
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 101 {
            return .upgradeRefused(host, http.statusCode)
        }
        switch code {
        case .cannotFindHost?, .dnsLookupFailed?: return .hostNotFound(host)
        case .cannotConnectToHost?: return .refused(host, port)
        case .timedOut?: return connected ? .closedByRemote : .timedOut(host)
        case .notConnectedToInternet?, .internationalRoamingOff?, .dataNotAllowed?: return .unreachable(host)
        case .badServerResponse?: return .upgradeRefused(host, nil)
        case .networkConnectionLost?: return connected ? .closedByRemote : .refused(host, port)
        case .cancelled?: return connected ? .closedByRemote : .other(error.localizedDescription)
        default:
            if connected { return .closedByRemote }
            return .other(error.localizedDescription)
        }
    }

    // MARK: Receiving

    private func receive() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.done else { return }
                switch result {
                case .success(let message):
                    let bytes = Self.bytes(of: message)
                    if !bytes.isEmpty { self.events?(.bytes(bytes)) }
                    self.receive()
                case .failure(let error):
                    self.fail(error, task: task)
                }
            }
        }
    }

    private func fail(_ error: Error, task: URLSessionTask) {
        finish(Self.map(error, response: task.response, host: host, port: port, connected: opened))
    }

    private func finish(_ error: BBSConnectionError?) {
        guard !done else { return }
        close()
        events?(.closed(error))
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async {
            guard !self.done, !self.opened else { return }
            self.opened = true
            self.events?(.opened)
            self.receive()
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.finish(.closedByRemote) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            if let error { self.fail(error, task: task) } else { self.finish(.closedByRemote) }
        }
    }
}
