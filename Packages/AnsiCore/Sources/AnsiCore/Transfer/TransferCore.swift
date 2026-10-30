import Foundation

/// The time source an engine reads for its timeouts. Engines never call `Date()` themselves, so
/// tests drive every timeout with a `ManualTransferClock`.
public protocol TransferClock: AnyObject {
    var now: TimeInterval { get }
}

public final class SystemTransferClock: TransferClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public final class ManualTransferClock: TransferClock {
    public var now: TimeInterval
    public init(start: TimeInterval = 0) { now = start }
    public func advance(_ seconds: TimeInterval) { now += seconds }
}

public enum TransferProtocolKind: String, CaseIterable, Sendable {
    case xmodem
    case xmodemCRC = "xmodem-crc"
    case xmodem1K = "xmodem-1k"
    case ymodem
    case ymodemG = "ymodem-g"
    case zmodem
    case kermit

    public var displayName: String {
        switch self {
        case .xmodem: return "XMODEM"
        case .xmodemCRC: return "XMODEM-CRC"
        case .xmodem1K: return "XMODEM-1K"
        case .ymodem: return "YMODEM"
        case .ymodemG: return "YMODEM-G"
        case .zmodem: return "ZMODEM"
        case .kermit: return "Kermit"
        }
    }

    /// Whether the protocol carries file names (and so can send more than one file).
    public var isBatch: Bool {
        switch self {
        case .xmodem, .xmodemCRC, .xmodem1K: return false
        default: return true
        }
    }
}

public enum TransferDirection: String, Sendable { case send, receive }

public enum TransferStatus: Equatable, Sendable {
    case idle, running, completed, failed(String), cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// One file that went across the line in full.
public struct TransferredFile: Equatable, Sendable {
    /// The name it was stored under (receive) or sent as (send).
    public var name: String
    /// The name the other side used.
    public var remoteName: String
    public var bytes: Int
    /// SHA-256 of the whole file, lowercase hex.
    public var sha256: String
    public var url: URL?
    /// Bytes that were already on disk from an earlier attempt (ZMODEM crash recovery).
    public var resumedFrom: Int

    public init(name: String, remoteName: String, bytes: Int, sha256: String, url: URL? = nil, resumedFrom: Int = 0) {
        self.name = name
        self.remoteName = remoteName
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
        self.resumedFrom = resumedFrom
    }
}

public enum TransferEvent: Equatable, Sendable {
    case log(String)
    case negotiated(String)
    case fileStarted(name: String, size: Int?, offset: Int)
    case fileCompleted(TransferredFile)
    case fileSkipped(name: String, reason: String)
    /// A line error that the protocol recovered from (a retransmission).
    case recovered(String)
    case completed
    case failed(String)
    case cancelled(String)
}

public struct TransferProgress: Equatable, Sendable {
    public var fileName: String?
    /// Position in the current file.
    public var fileBytes = 0
    public var fileSize: Int?
    public var filesCompleted = 0
    /// Good file bytes moved this session, across files (resumed bytes are not counted).
    public var sessionBytes = 0
    public init() {}
}

public enum XModemPadding: String, Sendable {
    /// Drop trailing SUB (0x1A) bytes from the final block (plain XMODEM only; YMODEM uses the size).
    case stripTrailingSUB
    /// Keep the final block as received.
    case keep
}

public struct TransferOptions: Sendable {
    // XMODEM and YMODEM
    public var xmodemPadding = XModemPadding.stripTrailingSUB
    /// Seconds between the receiver's start characters (C, G or NAK).
    public var startInterval: TimeInterval = 3
    /// Start characters sent before plain XMODEM falls back from C to NAK, and before giving up.
    public var startTries = 10
    public var blockTimeout: TimeInterval = 10
    public var maxRetries = 10
    public var senderStartTimeout: TimeInterval = 60
    /// Seconds of line silence to wait after a bad block before NAKing it.
    public var purgeTime: TimeInterval = 1

    // ZMODEM
    /// Data subpacket length when sending (256...8192).
    public var zmodemBlockSize = 1024
    public var zmodemUseCRC32 = true
    /// Escape every control character (the ESCCTL option).
    public var zmodemEscapeControl = false
    /// Also escape 0xFF and CR, for telnet paths that are not in BINARY mode.
    public var zmodemEscapeTelnet = false
    /// Receive buffer size advertised in ZRINIT (0 = full streaming).
    public var zmodemReceiveWindow = 0
    public var headerTimeout: TimeInterval = 10
    /// Sender: ask the receiver to resume (ZCRESUM). Receiver: resume a kept `.part` file.
    public var resume = false

    // Kermit
    public var kermitCheckType = 3
    /// Longest packet we accept and send (94 is the basic maximum; more enables long packets).
    public var kermitMaxPacket = 4000
    /// Sliding window size we offer (1 is stop and wait).
    public var kermitWindow = 1
    /// Ask for 8th bit prefixing even on an 8 bit clean line.
    public var kermitForceEighthBitPrefix = false
    public var kermitUseRepeat = true
    public var kermitUseAttributes = true
    public var kermitTimeout: TimeInterval = 10

    public init() {}
}

/// The common machinery of every protocol engine: an output queue the caller drains, an event
/// queue, a single timer driven by the injected clock, and the status. Subclasses override the
/// internal hooks. Nothing here does I/O.
public class TransferEngine {
    public let clock: TransferClock
    public let options: TransferOptions
    public internal(set) var status = TransferStatus.idle
    public internal(set) var progress = TransferProgress()
    public var protocolName: String { "transfer" }

    private var outbox: [UInt8] = []
    private var outHead = 0
    private var events: [TransferEvent] = []
    private var deadline: TimeInterval?

    init(clock: TransferClock, options: TransferOptions) {
        self.clock = clock
        self.options = options
    }

    // MARK: Public driving API

    public func start() {
        guard status == .idle else { return }
        status = .running
        begin()
    }

    /// Bytes from the line.
    public func receive(_ bytes: [UInt8]) {
        guard status == .running, !bytes.isEmpty else { return }
        handle(bytes)
    }

    /// Fires the timer if it has expired. Call it regularly (a 10 Hz timer is plenty).
    public func tick() {
        guard status == .running, let due = deadline, clock.now >= due else { return }
        deadline = nil
        timedOut()
    }

    /// Takes up to `max` bytes to send. Streaming protocols generate more only when asked, so how
    /// fast the caller writes is the flow control.
    public func takeOutput(max: Int = 65536) -> [UInt8] {
        if status == .running, outbox.count - outHead < max { refill(max - (outbox.count - outHead)) }
        let available = outbox.count - outHead
        guard available > 0 else { return [] }
        let count = Swift.min(max, available)
        let chunk = Array(outbox[outHead..<(outHead + count)])
        outHead += count
        if outHead == outbox.count {
            outbox.removeAll(keepingCapacity: true)
            outHead = 0
        } else if outHead > 1 << 16 {
            outbox.removeFirst(outHead)
            outHead = 0
        }
        return chunk
    }

    public var pendingOutputCount: Int { outbox.count - outHead }

    public func takeEvents() -> [TransferEvent] {
        defer { events.removeAll() }
        return events
    }

    /// Cancels: tells the other side, cleans up the current file, and stops.
    public func cancel(reason: String = "cancelled by user") {
        guard !status.isFinished else { return }
        if status == .running { send(cancelSequence()) }
        abortCurrentFile()
        deadline = nil
        status = .cancelled
        emit(.cancelled(reason))
    }

    // MARK: Hooks for subclasses

    func begin() {}
    func handle(_ bytes: [UInt8]) {}
    func timedOut() {}
    func refill(_ budget: Int) {}
    /// What goes on the line when we cancel. XMODEM family and ZMODEM: the lrzsz string.
    func cancelSequence() -> [UInt8] { Array(repeating: 0x18, count: 10) + Array(repeating: 0x08, count: 10) }
    /// Removes or keeps the partial file of an unfinished receive.
    func abortCurrentFile() {}

    // MARK: Helpers

    func send(_ bytes: [UInt8]) { outbox.append(contentsOf: bytes) }
    func send(_ byte: UInt8) { outbox.append(byte) }
    func emit(_ event: TransferEvent) { events.append(event) }
    func arm(_ seconds: TimeInterval) { deadline = clock.now + seconds }
    func disarm() { deadline = nil }
    var timerArmed: Bool { deadline != nil }

    func complete() {
        guard !status.isFinished else { return }
        deadline = nil
        status = .completed
        emit(.completed)
    }

    /// Fails the transfer. With `cancelRemote` the cancel sequence is sent so the other side stops too.
    func fail(_ reason: String, cancelRemote: Bool = true) {
        guard !status.isFinished else { return }
        if cancelRemote { send(cancelSequence()) }
        abortCurrentFile()
        deadline = nil
        status = .failed(reason)
        emit(.failed(reason))
    }
}
