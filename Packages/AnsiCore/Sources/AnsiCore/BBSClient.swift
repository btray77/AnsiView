import Foundation
import Network

/// Releases received bytes at a modem speed, the way the file player does: baud / 10 bytes a
/// second (8N1 framing). Baud 0 releases everything at once.
public struct LinePacer {
    public var baud: Int
    private var buffer: [UInt8] = []
    private var head = 0
    /// Bits of line time not yet spent on a whole byte.
    private var credit: Double = 0

    public init(baud: Int) {
        self.baud = baud
    }

    public var pending: Int { buffer.count - head }

    public mutating func push(_ bytes: [UInt8]) {
        buffer += bytes
    }

    /// The bytes due after `elapsed` more seconds of line time.
    public mutating func release(elapsed: TimeInterval) -> [UInt8] {
        guard pending > 0 else {
            // An idle line does not save up time for a later burst.
            credit = 0
            return []
        }
        let count: Int
        if baud <= 0 {
            count = pending
        } else {
            credit += max(0, elapsed) * Double(baud)
            count = min(pending, Int((credit + 1e-6) / 10))
            credit -= Double(count) * 10
            if count == pending { credit = 0 }
        }
        let out = Array(buffer[head..<(head + count)])
        head += count
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 65536 {
            buffer.removeFirst(head)
            head = 0
        }
        return out
    }
}

/// Why a BBS connection ended, in words a caller can show.
public enum BBSConnectionError: Error, Equatable {
    case hostNotFound(String)
    case refused(String, Int)
    case timedOut(String)
    case unreachable(String)
    case closedByRemote
    case other(String)
    /// This build cannot make that kind of connection.
    case unsupported(String)
    /// SSH: the server turned down every way AnsiView tried to log in.
    case authenticationFailed(String)
    /// SSH: the server's host key is not the one saved for it (host, saved fingerprint, offered fingerprint).
    case hostKeyChanged(String, String, String)
    /// SSH: the user did not trust a new host key.
    case hostKeyNotTrusted(String)
    /// SSH: no key exchange, host key or cipher in common (host, what failed).
    case algorithmMismatch(String, String)
    /// WebSocket over TLS: the secure connection failed (host, what failed).
    case tls(String, String)
    /// WebSocket: the server answered with HTTP instead of upgrading (host, status code if known).
    case upgradeRefused(String, Int?)
    /// RLogin: the server refused the login (its message).
    case rloginRefused(String)

    public var message: String {
        switch self {
        case .hostNotFound(let host):
            return "The BBS address \"\(host)\" could not be found. Check the spelling, or your internet connection."
        case .refused(let host, let port):
            return "\(host) refused the connection on port \(port). The BBS may be down, or it may use a different port."
        case .timedOut(let host):
            return "No answer from \(host). The BBS may be down or busy; try again later."
        case .unreachable(let host):
            return "\(host) cannot be reached from this network. Check your internet connection."
        case .closedByRemote:
            return "The BBS closed the connection."
        case .other(let description):
            return "The connection failed: \(description)"
        case .unsupported(let text):
            return text
        case .authenticationFailed(let detail):
            return "The SSH server did not accept the login. \(detail)"
        case .hostKeyChanged(let host, let saved, let offered):
            return "WARNING: the SSH host key of \(host) has changed, so AnsiView did not connect. Saved key: \(saved). Key offered now: \(offered). Someone may be pretending to be this BBS, or the sysop replaced the key. Ask the sysop before you forget the saved key."
        case .hostKeyNotTrusted(let host):
            return "The host key of \(host) was not trusted, so AnsiView did not connect."
        case .algorithmMismatch(let host, let detail):
            return "\(host) only offers SSH methods that AnsiView cannot use yet (\(detail)). Many BBS SSH servers use older methods (diffie-hellman key exchange, ssh-rsa host keys); try the BBS's telnet port instead."
        case .tls(let host, let detail):
            return "The secure (TLS) connection to \(host) failed: \(detail) Check the address, or turn off Secure (wss) if the BBS does not offer it."
        case .upgradeRefused(let host, let status):
            let code = status.map { " (HTTP status \($0))" } ?? ""
            return "\(host) answered as a web server but refused the WebSocket connection\(code). Check the WebSocket path and port the BBS publishes."
        case .rloginRefused(let text):
            let shown = text.isEmpty ? "no reason given." : text
            return "The RLogin server refused the login: \(shown)" + (".!?".contains(shown.last ?? ".") ? "" : ".")
        }
    }

    public static func from(_ error: NWError, host: String, port: Int, connected: Bool) -> BBSConnectionError {
        switch error {
        case .dns:
            return .hostNotFound(host)
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused(host, port)
            case .ETIMEDOUT: return .timedOut(host)
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN: return .unreachable(host)
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNABORTED:
                return connected ? .closedByRemote : .refused(host, port)
            default: return .other(error.localizedDescription)
            }
        default:
            return .other(error.localizedDescription)
        }
    }
}

public enum BBSClientState: Equatable {
    case idle
    case connecting
    case connected
    /// Ended; nil when the user disconnected.
    case closed(BBSConnectionError?)
}

/// A connection to a BBS over any `BBSTransport` (TCP for telnet and raw, RLogin, WebSocket, or
/// an SSH transport handed in by the app), with telnet negotiation on top when the settings ask.
/// Public methods may be called from any thread; work and callbacks happen on `queue`.
///
/// For file transfers: `send(_:)` and `onData` carry any byte on every transport. On telnet the
/// bytes are escaped (255 doubled) and IAC commands stripped, and CR is sent as CR NUL unless
/// BINARY is on; `isByteClean` says whether a transfer can run without that care.
public final class BBSClient {
    public let host: String
    public let port: Int
    public let settings: TransportSettings
    public var mode: ConnectionMode { settings.mode }
    public let connectTimeout: TimeInterval
    public let queue: DispatchQueue

    /// State changes, on `queue`.
    public var onState: ((BBSClientState) -> Void)?
    /// Data from the BBS with telnet commands removed, on `queue`.
    public var onData: (([UInt8]) -> Void)?
    /// Every byte read from the transport, before telnet decoding, on `queue` (for logs).
    public var onReceived: (([UInt8]) -> Void)?
    /// Every byte written to the transport (data and negotiation), on `queue`.
    public var onSent: (([UInt8]) -> Void)?

    public private(set) var state = BBSClientState.idle
    public private(set) var telnet: TelnetSession

    private var transport: BBSTransport?
    private var timeoutWork: DispatchWorkItem?

    public convenience init(host: String, port: Int, mode: ConnectionMode, columns: Int, rows: Int,
                            connectTimeout: TimeInterval = 15, queue: DispatchQueue = .main,
                            terminalTypes: [String] = ["ANSI", "ANSI-BBS", "VT100"]) {
        self.init(host: host, port: port, settings: TransportSettings(mode: mode), columns: columns, rows: rows,
                  connectTimeout: connectTimeout, queue: queue, terminalTypes: terminalTypes)
    }

    /// `transport` is used when given (the app's SSH transport, or a test's); otherwise one is made
    /// for the mode. SSH has no built in transport (it needs the app's NIO code).
    public init(host: String, port: Int, settings: TransportSettings, columns: Int, rows: Int,
                connectTimeout: TimeInterval = 15, queue: DispatchQueue = .main,
                terminalTypes: [String] = ["ANSI", "ANSI-BBS", "VT100"], transport: BBSTransport? = nil) {
        self.host = host
        self.port = port
        self.settings = settings
        self.connectTimeout = connectTimeout
        self.queue = queue
        self.transport = transport
        telnet = TelnetSession(columns: columns, rows: rows, terminalTypes: terminalTypes)
    }

    /// True when bytes pass unchanged both ways: always off telnet; on telnet only with BINARY
    /// enabled in both directions.
    public var isByteClean: Bool {
        !settings.usesTelnet || (telnet.localEnabled(.binary) && telnet.remoteEnabled(.binary))
    }

    public func connect() {
        queue.async { self.start() }
    }

    /// Sends typed data: telnet escaped when telnet runs, unchanged otherwise.
    public func send(_ bytes: [UInt8]) {
        queue.async {
            guard self.state == .connected, !bytes.isEmpty else { return }
            self.write(self.settings.usesTelnet ? self.telnet.encode(bytes) : bytes)
        }
    }

    /// A new terminal size: reported by telnet NAWS (when accepted) and to the transport (SSH).
    public func resize(columns: Int, rows: Int) {
        queue.async {
            let report = self.telnet.resize(columns: columns, rows: rows)
            guard self.state == .connected else { return }
            if self.settings.usesTelnet, !report.isEmpty { self.write(report) }
            self.transport?.resize(columns: columns, rows: rows)
        }
    }

    public func disconnect() {
        queue.async { self.finish(nil) }
    }

    // MARK: Connection

    private func makeTransport() -> BBSTransport? {
        switch settings.mode {
        case .telnet, .raw:
            return TCPTransport(host: host, port: port, connectTimeout: connectTimeout, queue: queue)
        case .rlogin:
            return RLoginTransport(host: host, port: port, settings: settings, connectTimeout: connectTimeout, queue: queue)
        case .webSocket:
            return WebSocketTransport(host: host, port: port, settings: settings, connectTimeout: connectTimeout, queue: queue)
        case .ssh:
            return nil
        }
    }

    private func start() {
        guard state == .idle else { return }
        guard (1...65535).contains(port) else {
            finish(.other("\(port) is not a valid port number (1 to 65535)."))
            return
        }
        if transport == nil { transport = makeTransport() }
        guard let transport else {
            finish(.unsupported("SSH connections need the AnsiView app."))
            return
        }
        setState(.connecting)
        transport.events = { [weak self] event in self?.handle(event) }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.finish(.timedOut(self.host))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + connectTimeout, execute: work)
        transport.open()
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .opened:
            guard state == .connecting else { return }
            timeoutWork?.cancel()
            setState(.connected)
            if settings.usesTelnet { write(telnet.start()) }
        case .bytes(let bytes):
            guard state == .connected else { return }
            deliver(bytes)
        case .closed(let error):
            finish(error, closeTransport: false)
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        onReceived?(bytes)
        guard settings.usesTelnet else {
            onData?(bytes)
            return
        }
        let (data, reply) = telnet.receive(bytes)
        if !reply.isEmpty { write(reply) }
        if !data.isEmpty { onData?(data) }
    }

    private func write(_ bytes: [UInt8]) {
        guard let transport, !bytes.isEmpty else { return }
        onSent?(bytes)
        transport.write(bytes)
    }

    private func finish(_ error: BBSConnectionError?, closeTransport: Bool = true) {
        if case .closed = state { return }
        timeoutWork?.cancel()
        let transport = self.transport
        transport?.events = nil
        if closeTransport { transport?.close() }
        setState(.closed(error))
    }

    private func setState(_ newState: BBSClientState) {
        state = newState
        onState?(newState)
    }
}
