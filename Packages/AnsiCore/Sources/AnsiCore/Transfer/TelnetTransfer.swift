/// Runs a transfer engine over a telnet connection.
///
/// Incoming: every byte goes through `TelnetSession.receive`, so IAC commands and option
/// negotiation are removed (and answered) before the engine sees anything, and `IAC IAC` becomes
/// a data 255. Outgoing: engine bytes go through `TelnetSession.encode`, which doubles 255.
///
/// Binary transfers need TELNET BINARY (RFC 856) in both directions: without it a conforming
/// peer turns CR into CR NUL and back, which round trips, but many BBS telnet servers handle it
/// differently, and 8 bit data is not guaranteed. `start()` asks for BINARY both ways and
/// `isByteClean` reports whether the other side agreed. When it did not, use ZMODEM with
/// `zmodemEscapeTelnet` (escapes CR and 0xFF) or Kermit (7 bit safe with prefixing).
///
/// SSH and WebSocket channels need no wrapper: an SSH channel is byte clean, and WebSocket
/// carries the bytes unchanged as long as binary frames (opcode 2) are used; text frames must
/// not be used because they require valid UTF-8.
public struct TelnetTransferChannel {
    public private(set) var session: TelnetSession

    public init(session: TelnetSession = TelnetSession(columns: 80, rows: 25)) {
        self.session = session
    }

    /// The opening negotiation for a fresh connection, including the BINARY requests. For a
    /// connection that is already open (the terminal's session), use `requestBinary()` instead.
    public mutating func start() -> [UInt8] {
        session.start() + session.requestBinary()
    }

    public mutating func requestBinary() -> [UInt8] { session.requestBinary() }

    /// Bytes from the network: the data for the engine and the telnet replies to send back.
    public mutating func decode(_ bytes: [UInt8]) -> (data: [UInt8], reply: [UInt8]) {
        session.receive(bytes)
    }

    /// Engine output ready for the network.
    public func encode(_ bytes: [UInt8]) -> [UInt8] { session.encode(bytes) }

    /// Both directions are in BINARY mode.
    public var isByteClean: Bool { session.localEnabled(.binary) && session.remoteEnabled(.binary) }
}
