import Foundation
import Network

/// What a transport reports to `BBSClient`, always on the client's queue.
public enum TransportEvent: Equatable {
    /// The channel is up (TCP connected, SSH shell started, WebSocket upgraded, RLogin accepted).
    case opened
    case bytes([UInt8])
    /// True while the transport waits for the user (an SSH host key alert): the connect timeout
    /// stops, and starts again from the full time when the user has answered.
    case waitingForUser(Bool)
    /// Ended; nil when `close()` was asked for.
    case closed(BBSConnectionError?)
}

/// A byte clean duplex channel to a BBS. `BBSClient` runs telnet over it when the settings ask
/// for it; otherwise the bytes pass unchanged both ways, which is what file transfers need:
/// SSH channel data, WebSocket binary frames and RLogin after its handshake carry any byte.
///
/// Every method is called on the client's queue and every event must be delivered on it.
public protocol BBSTransport: AnyObject {
    var events: ((TransportEvent) -> Void)? { get set }
    func open()
    func write(_ bytes: [UInt8])
    /// Writes and calls `completion` (on the client's queue) once the bytes have left for the
    /// network or the write failed, so a file transfer sends only as fast as the line drains.
    func write(_ bytes: [UInt8], completion: @escaping () -> Void)
    /// The terminal size changed (SSH sends window-change; the others ignore it).
    func resize(columns: Int, rows: Int)
    func close()
}

public extension BBSTransport {
    /// Transports without a write confirmation complete at once.
    func write(_ bytes: [UInt8], completion: @escaping () -> Void) {
        write(bytes)
        completion()
    }
}

/// The per entry choices a transport needs (from `BBSEntry`, or made by hand in tests).
public struct TransportSettings: Equatable {
    public var mode: ConnectionMode
    /// Sent as the SSH PTY term, the RLogin terminal and first in the telnet TERMINAL-TYPE cycle.
    public var terminalType = "ANSI"
    /// The simulated line speed (RLogin reports it; 0 means unlimited).
    public var baud = 0
    public var username = ""
    public var webSocketPath = "/"
    public var webSocketSecure = false
    /// Telnet over TLS.
    public var telnetSecure = false
    public var webSocketSubprotocols: [String] = []
    public var webSocketTelnet = false
    public var rloginClientUser = ""
    public var rloginServerUser = ""
    public var rloginClientIsPassword = false
    /// The Keychain password, filled in by the app at connect time (never stored in an entry).
    public var password: String?
    public var sshTrustNewHostKey = false

    public init(mode: ConnectionMode) {
        self.mode = mode
    }

    public init(entry: BBSEntry) {
        mode = entry.mode
        terminalType = entry.terminalType
        baud = entry.baud
        username = entry.username ?? ""
        webSocketPath = entry.webSocketPath
        webSocketSecure = entry.webSocketSecure
        telnetSecure = entry.mode == .telnet && entry.telnetSecure
        webSocketSubprotocols = Self.subprotocols(entry.webSocketSubprotocols)
        webSocketTelnet = entry.webSocketTelnet
        rloginClientUser = entry.rloginClientUser
        rloginServerUser = entry.rloginServerUser
        rloginClientIsPassword = entry.rloginClientIsPassword
        sshTrustNewHostKey = entry.sshTrustNewHostKey
    }

    /// Telnet negotiation runs on telnet connections and inside a WebSocket that carries telnet.
    public var usesTelnet: Bool {
        mode == .telnet || (mode == .webSocket && webSocketTelnet)
    }

    /// "telnet, binary" as a list; empty items dropped.
    public static func subprotocols(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// A TCP byte stream (Network.framework), used for telnet and raw connections.
public final class TCPTransport: BBSTransport {
    public var events: ((TransportEvent) -> Void)?
    public let host: String
    public let port: Int
    public let connectTimeout: TimeInterval
    public let queue: DispatchQueue

    private var connection: NWConnection?
    private var ready = false
    private var done = false

    public init(host: String, port: Int, connectTimeout: TimeInterval, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.queue = queue
    }

    public func open() {
        guard connection == nil, !done else { return }
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            finish(.other("\(port) is not a valid port number (1 to 65535)."))
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded(.up)))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                      using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
        connection.start(queue: queue)
    }

    public func write(_ bytes: [UInt8]) {
        guard let connection, ready, !bytes.isEmpty else { return }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.finish(.from(error, host: self.host, port: self.port, connected: true))
        })
    }

    public func write(_ bytes: [UInt8], completion: @escaping () -> Void) {
        guard let connection, ready, !bytes.isEmpty else {
            completion()
            return
        }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let self, let error { self.finish(.from(error, host: self.host, port: self.port, connected: true)) }
            completion()
        })
    }

    public func resize(columns: Int, rows: Int) {}

    public func close() {
        guard !done else { return }
        done = true
        let connection = self.connection
        self.connection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !ready, !done else { return }
            ready = true
            events?(.opened)
            receive()
        case .waiting(let error), .failed(let error):
            // A terminal reports the problem rather than silently retrying.
            finish(.from(error, host: host, port: port, connected: ready))
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.done else { return }
            if let data, !data.isEmpty { self.events?(.bytes(Array(data))) }
            if let error {
                self.finish(.from(error, host: self.host, port: self.port, connected: true))
            } else if complete {
                self.finish(.closedByRemote)
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ error: BBSConnectionError?) {
        guard !done else { return }
        close()
        events?(.closed(error))
    }
}
