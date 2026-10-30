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

/// A connection to a BBS over TCP (Network.framework), speaking telnet or raw bytes.
/// Public methods may be called from any thread; work and callbacks happen on `queue`.
public final class BBSClient {
    public let host: String
    public let port: Int
    public let mode: ConnectionMode
    public let connectTimeout: TimeInterval
    public let queue: DispatchQueue

    /// State changes, on `queue`.
    public var onState: ((BBSClientState) -> Void)?
    /// Data from the BBS with telnet commands removed, on `queue`.
    public var onData: (([UInt8]) -> Void)?
    /// Every byte read from the network, before telnet decoding, on `queue` (for logs).
    public var onReceived: (([UInt8]) -> Void)?
    /// Every byte written to the network (data and negotiation), on `queue`.
    public var onSent: (([UInt8]) -> Void)?

    public private(set) var state = BBSClientState.idle
    public private(set) var telnet: TelnetSession

    private var connection: NWConnection?
    private var timeoutWork: DispatchWorkItem?

    public init(host: String, port: Int, mode: ConnectionMode, columns: Int, rows: Int,
                connectTimeout: TimeInterval = 15, queue: DispatchQueue = .main,
                terminalTypes: [String] = ["ANSI", "ANSI-BBS", "VT100"]) {
        self.host = host
        self.port = port
        self.mode = mode
        self.connectTimeout = connectTimeout
        self.queue = queue
        telnet = TelnetSession(columns: columns, rows: rows, terminalTypes: terminalTypes)
    }

    public func connect() {
        queue.async { self.start() }
    }

    /// Sends typed data: telnet escaped in telnet mode, unchanged in raw mode.
    public func send(_ bytes: [UInt8]) {
        queue.async {
            guard self.state == .connected, !bytes.isEmpty else { return }
            self.write(self.mode == .telnet ? self.telnet.encode(bytes) : bytes)
        }
    }

    /// A new terminal size, reported to the BBS when it accepted NAWS.
    public func resize(columns: Int, rows: Int) {
        queue.async {
            let report = self.telnet.resize(columns: columns, rows: rows)
            if self.state == .connected, self.mode == .telnet, !report.isEmpty { self.write(report) }
        }
    }

    public func disconnect() {
        queue.async { self.finish(nil) }
    }

    // MARK: Connection

    private func start() {
        guard state == .idle else { return }
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            finish(.other("\(port) is not a valid port number (1 to 65535)."))
            return
        }
        setState(.connecting)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                      using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.connectionChanged(state) }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.finish(.timedOut(self.host))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + connectTimeout, execute: work)
        connection.start(queue: queue)
    }

    private func connectionChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            guard state == .connecting else { return }
            timeoutWork?.cancel()
            setState(.connected)
            if mode == .telnet { write(telnet.start()) }
            receive()
        case .waiting(let error), .failed(let error):
            // A terminal reports the problem rather than silently retrying.
            finish(.from(error, host: host, port: port, connected: state == .connected))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.state == .connected else { return }
            if let data, !data.isEmpty { self.deliver(Array(data)) }
            if let error {
                self.finish(.from(error, host: self.host, port: self.port, connected: true))
            } else if complete {
                self.finish(.closedByRemote)
            } else {
                self.receive()
            }
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        onReceived?(bytes)
        guard mode == .telnet else {
            onData?(bytes)
            return
        }
        let (data, reply) = telnet.receive(bytes)
        if !reply.isEmpty { write(reply) }
        if !data.isEmpty { onData?(data) }
    }

    private func write(_ bytes: [UInt8]) {
        guard let connection else { return }
        onSent?(bytes)
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error, self.state == .connected else { return }
            self.finish(.from(error, host: self.host, port: self.port, connected: true))
        })
    }

    private func finish(_ error: BBSConnectionError?) {
        if case .closed = state { return }
        timeoutWork?.cancel()
        let connection = self.connection
        self.connection = nil
        setState(.closed(error))
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    private func setState(_ newState: BBSClientState) {
        state = newState
        onState?(newState)
    }
}
