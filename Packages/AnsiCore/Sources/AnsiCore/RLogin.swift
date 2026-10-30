import Foundation

/// RLogin (RFC 1282) client handshake. After it the stream is byte clean.
///
/// Not done, and why: the window size. The server asks for it with TCP urgent data (an out of
/// band 0x80 byte), which Network.framework does not expose, so the request cannot be seen; the
/// `FF FF s s` size cookie sent unasked would reach the input of servers that do not expect it.
/// The sandbox also cannot bind a privileged (below 1024) source port, which Unix rlogind uses to
/// trust a client; BBS RLogin servers (Synchronet, Mystic and others) accept any source port.
public enum RLogin {
    /// `NUL client-user NUL server-user NUL terminal/speed NUL`.
    public static func handshake(clientUser: String, serverUser: String, terminal: String) -> [UInt8] {
        [0] + Array(clientUser.utf8) + [0] + Array(serverUser.utf8) + [0] + Array(terminal.utf8) + [0]
    }

    /// `ansi/38400`: the terminal type in lower case and the line speed (38400 when unlimited).
    public static func terminalField(_ settings: TransportSettings) -> String {
        let type = settings.terminalType.trimmingCharacters(in: .whitespaces).lowercased()
        let speed = settings.baud > 0 ? settings.baud : 38400
        return "\(type.isEmpty ? "ansi" : type)/\(speed)"
    }

    /// The user names sent: the RLogin fields, each falling back to the username; the client user
    /// is the saved password when the entry says so (empty when none is saved).
    public static func users(_ settings: TransportSettings) -> (client: String, server: String) {
        let client = settings.rloginClientIsPassword ? (settings.password ?? "")
            : settings.rloginClientUser.isEmpty ? settings.username : settings.rloginClientUser
        let server = settings.rloginServerUser.isEmpty ? settings.username : settings.rloginServerUser
        return (client, server)
    }
}

/// The server's answer to the handshake: a NUL byte accepts; anything else starts an error
/// message (BSD rlogind sends 0x01 and a line of text).
public struct RLoginAnswer {
    public enum Result: Equatable {
        case waiting
        case accepted(rest: [UInt8])
        case refused(String)
    }

    public static let maxMessage = 512
    private var refusing = false
    private var message: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> Result {
        var index = 0
        if !refusing {
            guard let first = bytes.first else { return .waiting }
            if first == 0 { return .accepted(rest: Array(bytes.dropFirst())) }
            refusing = true
            // 0x01 is the usual error marker; any other byte is part of the text.
            index = first == 1 ? 1 : 0
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 10 || byte == 13 { return .refused(text) }
            message.append(byte)
            if message.count >= Self.maxMessage { return .refused(text) }
            index += 1
        }
        return .waiting
    }

    /// The connection closed while waiting: the message so far, if a refusal had started.
    public func ended() -> String? {
        refusing ? text : nil
    }

    private var text: String {
        String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// RLogin over TCP: sends the handshake when connected and reports `opened` only after the
/// server accepts.
public final class RLoginTransport: BBSTransport {
    public var events: ((TransportEvent) -> Void)?
    private let tcp: TCPTransport
    private let settings: TransportSettings
    private var answer = RLoginAnswer()
    private var accepted = false
    private var done = false

    public init(host: String, port: Int, settings: TransportSettings, connectTimeout: TimeInterval, queue: DispatchQueue) {
        tcp = TCPTransport(host: host, port: port, connectTimeout: connectTimeout, queue: queue)
        self.settings = settings
    }

    public func open() {
        tcp.events = { [weak self] event in self?.handle(event) }
        tcp.open()
    }

    public func write(_ bytes: [UInt8]) {
        guard accepted else { return }
        tcp.write(bytes)
    }

    public func resize(columns: Int, rows: Int) {}

    public func close() {
        done = true
        tcp.close()
    }

    private func handle(_ event: TransportEvent) {
        guard !done else { return }
        switch event {
        case .opened:
            let users = RLogin.users(settings)
            tcp.write(RLogin.handshake(clientUser: users.client, serverUser: users.server,
                                       terminal: RLogin.terminalField(settings)))
        case .bytes(let bytes):
            guard !accepted else {
                events?(.bytes(bytes))
                return
            }
            switch answer.feed(bytes) {
            case .waiting: break
            case .accepted(let rest):
                accepted = true
                events?(.opened)
                if !rest.isEmpty { events?(.bytes(rest)) }
            case .refused(let text):
                close()
                events?(.closed(.rloginRefused(text)))
            }
        case .waitingForUser:
            events?(event)
        case .closed(let error):
            done = true
            if !accepted, let text = answer.ended() {
                events?(.closed(.rloginRefused(text)))
            } else {
                events?(.closed(error))
            }
        }
    }
}
