/// Watches terminal output for the start of a file transfer, so the terminal can start the
/// matching engine without the user picking a protocol (auto download, as Telix, Qmodem and
/// SyncTERM did).
///
/// - `**` ZDLE `B00`: a ZMODEM sender's ZRQINIT (the BBS runs `sz`): receive.
/// - `**` ZDLE `B01`: a ZMODEM receiver's ZRINIT (the BBS runs `rz`): offer to send.
/// - MARK, length, SP, `S`: a Kermit Send-Init with sequence 0 (the BBS runs `kermit -s`): receive.
/// - MARK, length, SP, `N`: a Kermit receiver's opening NAK (the BBS runs `kermit -r`): offer to send.
///
/// XMODEM and YMODEM senders send nothing until the receiver asks, so they cannot be detected;
/// the user starts those. A pattern split across feeds is still found.
public struct TransferStartDetector {
    public enum Kind: String, Equatable, Sendable {
        case zmodemReceive, zmodemSend, kermitReceive, kermitSend

        public var kind: TransferProtocolKind { self == .zmodemReceive || self == .zmodemSend ? .zmodem : .kermit }
        public var direction: TransferDirection { self == .zmodemReceive || self == .kermitReceive ? .receive : .send }
    }

    public struct Match: Equatable, Sendable {
        public var kind: Kind
        /// The part of this feed before the start sequence: still terminal output.
        public var terminalBytes: [UInt8]
        /// The start sequence (with any part held from earlier feeds) and everything after it:
        /// feed these to the new transfer session.
        public var transferBytes: [UInt8]
    }

    private var recent: [UInt8] = []
    static let longest = 6

    public init() {}

    public mutating func reset() { recent.removeAll() }

    public mutating func scan(_ bytes: [UInt8]) -> Match? {
        var window = recent
        for index in bytes.indices {
            window.append(bytes[index])
            if window.count > Self.longest { window.removeFirst() }
            guard let (kind, length) = Self.match(window) else { continue }
            let fromCurrent = min(index + 1, length)
            let transfer = Array(window.suffix(length)) + bytes[(index + 1)...]
            recent.removeAll()
            return Match(kind: kind, terminalBytes: Array(bytes[..<(index + 1 - fromCurrent)]), transferBytes: transfer)
        }
        recent = Array(window.suffix(Self.longest - 1))
        return nil
    }

    /// Scans on a copy (for one shot checks).
    public func scanned(_ bytes: [UInt8]) -> Match? {
        var copy = self
        return copy.scan(bytes)
    }

    private static func match(_ w: [UInt8]) -> (Kind, Int)? {
        let n = w.count
        if n >= 6, w[n - 6] == 0x2A, w[n - 5] == 0x2A, w[n - 4] == 0x18, w[n - 3] == 0x42, w[n - 2] == 0x30 {
            if w[n - 1] == 0x30 { return (.zmodemReceive, 6) }
            if w[n - 1] == 0x31 { return (.zmodemSend, 6) }
        }
        if n >= 4, w[n - 4] == KermitCodec.mark, (0x20...0x7E).contains(w[n - 3]), w[n - 2] == 0x20 {
            if w[n - 1] == UInt8(ascii: "S") { return (.kermitReceive, 4) }
            if w[n - 1] == UInt8(ascii: "N") { return (.kermitSend, 4) }
        }
        return nil
    }
}
