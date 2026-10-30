import Foundation

/// What the terminal asks the transfer layer to start.
public struct TransferRequest: Equatable, Sendable {
    public var kind: TransferProtocolKind
    public var direction: TransferDirection
    /// Bytes that arrived before the session existed (the detected start and what followed).
    public var initialBytes: [UInt8]
    /// The line carries every byte unchanged (telnet BINARY both ways, or not telnet at all).
    public var byteClean: Bool
    /// Shown in the panel: the line may change bytes this protocol needs.
    public var warning: String?
    /// The BBS started this transfer (its sender or receiver is already running).
    public var fromBBS = false

    /// The engine options for this request: telnet escapes or 8th bit prefixing on a line that
    /// is not byte clean, resume for ZMODEM downloads (ruling 5).
    public func options(base: TransferOptions = TransferOptions()) -> TransferOptions {
        var options = base
        if !byteClean {
            if kind == .zmodem { options.zmodemEscapeTelnet = true }
            if kind == .kermit { options.kermitForceEighthBitPrefix = true }
        }
        options.resume = kind == .zmodem && direction == .receive
        return options
    }
}

/// The ask bar's content for a detected transfer start.
public struct TransferOffer: Equatable, Sendable {
    public var detected: TransferStartDetector.Kind
    public var message: String
    public var acceptTitle: String
    public var ignoreTitle = "Ignore"

    init(_ detected: TransferStartDetector.Kind) {
        self.detected = detected
        let name = detected.kind.displayName
        if detected.direction == .receive {
            message = "The BBS wants to send files with \(name)."
            acceptTitle = "Receive"
        } else {
            message = "The BBS is ready to receive files with \(name)."
            acceptTitle = "Choose Files to Upload"
        }
    }
}

public enum TransferCoordinatorAction: Equatable, Sendable {
    /// Terminal output: give these to the screen (pacer, music, emulator).
    case showOnScreen([UInt8])
    /// Line data for the running session.
    case feedSession([UInt8])
    case showOffer(TransferOffer)
    case hideOffer
    /// Ask the telnet session for BINARY both ways.
    case requestBinary
    /// Show the open panel for a detected upload; answer with `filesChosen`.
    case chooseUploadFiles(TransferProtocolKind)
    case startSession(TransferRequest)
    /// Raw bytes for the BBS (the cancel sequence when a pending start is abandoned).
    case sendToRemote([UInt8])
    /// A start that never became a session was abandoned: the terminal resumes.
    case endPending
    /// The running session must fail (the connection went away).
    case failSession(String)
}

/// The terminal's side of file transfers as a pure state machine (rulings 1 to 3 of the
/// transfers UI plan): while idle it watches the stream for a ZMODEM or Kermit start and asks
/// before acting; it waits for telnet BINARY; while a session runs every byte goes to it.
/// Every call takes the time, so tests drive the clock.
public struct TransferCoordinator {
    public enum State: Equatable, Sendable {
        case idle
        case offering(TransferOffer)
        case choosingFiles(TransferProtocolKind)
        case negotiating(TransferProtocolKind, TransferDirection, deadline: Double)
        case running
    }

    /// Most bytes held while asking; more means the match was ordinary data.
    public static let maxHeld = 64 * 1024
    /// Seconds to wait for the BBS to answer the BINARY requests.
    public static let binaryWait: Double = 2
    /// Seconds after Ignore during which the same start is drawn without asking.
    public static let quietAfterIgnore: Double = 60
    /// Seconds after a cancelled or failed session during which starts are drawn, not asked about.
    public static let quietAfterAbort: Double = 30
    /// The lrzsz cancel string: 10 CAN then 10 backspaces (stops ZMODEM, X/YMODEM and Kermit senders).
    public static let cancelSequence: [UInt8] = Array(repeating: 0x18, count: 10) + Array(repeating: 0x08, count: 10)

    public var autoAcceptZmodem: Bool
    public let usesTelnet: Bool
    public private(set) var state = State.idle
    private var detector = TransferStartDetector()
    private var held: [UInt8] = []
    private var quietUntil: [TransferStartDetector.Kind: Double] = [:]
    private var quietAfterAbortUntil: Double = -.infinity
    /// The pending start came from the BBS (its sender or receiver is already running).
    private var remoteStarted = false

    public init(autoAcceptZmodem: Bool, usesTelnet: Bool) {
        self.autoAcceptZmodem = autoAcceptZmodem
        self.usesTelnet = usesTelnet
    }

    /// Keys are blocked and the screen is paused (waiting for BINARY or transferring).
    public var isTransferActive: Bool {
        switch state {
        case .negotiating, .running: return true
        default: return false
        }
    }

    public var heldCount: Int { held.count }

    /// Bytes from the BBS (after telnet decoding).
    public mutating func received(_ bytes: [UInt8], at now: Double, byteClean: Bool) -> [TransferCoordinatorAction] {
        switch state {
        case .running:
            return bytes.isEmpty ? [] : [.feedSession(bytes)]
        case .offering:
            held += bytes
            if held.count > Self.maxHeld {
                // Too much for a protocol start that waits for an answer: it was data.
                let release = held
                reset()
                return [.hideOffer, .showOnScreen(release)]
            }
            return []
        case .choosingFiles, .negotiating:
            held += bytes
            if held.count > Self.maxHeld { held.removeFirst(held.count - Self.maxHeld) }
            return []
        case .idle:
            guard let match = detector.scan(bytes) else { return bytes.isEmpty ? [] : [.showOnScreen(bytes)] }
            if now < quietAfterAbortUntil || now < (quietUntil[match.kind] ?? -.infinity) {
                detector.reset()
                return [.showOnScreen(match.terminalBytes + match.transferBytes)]
            }
            var actions: [TransferCoordinatorAction] = match.terminalBytes.isEmpty ? [] : [.showOnScreen(match.terminalBytes)]
            held = match.transferBytes
            remoteStarted = true
            if match.kind == .zmodemReceive, autoAcceptZmodem {
                actions += begin(match.kind.kind, .receive, at: now, byteClean: byteClean)
                return actions
            }
            let offer = TransferOffer(match.kind)
            state = .offering(offer)
            actions.append(.showOffer(offer))
            return actions
        }
    }

    /// The bar's accept button.
    public mutating func accept(at now: Double, byteClean: Bool) -> [TransferCoordinatorAction] {
        guard case .offering(let offer) = state else { return [] }
        if offer.detected.direction == .send {
            state = .choosingFiles(offer.detected.kind)
            return [.hideOffer, .chooseUploadFiles(offer.detected.kind)]
        }
        return [.hideOffer] + begin(offer.detected.kind, .receive, at: now, byteClean: byteClean)
    }

    /// The bar's Ignore button: the held bytes are drawn, nothing is sent (ruling 1).
    public mutating func ignore(at now: Double) -> [TransferCoordinatorAction] {
        guard case .offering(let offer) = state else { return [] }
        quietUntil[offer.detected] = now + Self.quietAfterIgnore
        let release = held
        reset()
        return [.hideOffer] + (release.isEmpty ? [] : [.showOnScreen(release)])
    }

    /// The open panel for a detected upload closed.
    public mutating func filesChosen(_ chosen: Bool, at now: Double, byteClean: Bool) -> [TransferCoordinatorAction] {
        guard case .choosingFiles(let kind) = state else { return [] }
        if chosen { return begin(kind, .send, at: now, byteClean: byteClean) }
        quietUntil[kind == .zmodem ? .zmodemSend : .kermitSend] = now + Self.quietAfterIgnore
        let release = held
        reset()
        return release.isEmpty ? [] : [.showOnScreen(release)]
    }

    /// Terminal > Download or Upload (files already chosen for an upload).
    public mutating func begin(kind: TransferProtocolKind, direction: TransferDirection, at now: Double,
                               byteClean: Bool) -> [TransferCoordinatorAction] {
        switch state {
        case .running, .negotiating: return []
        case .offering:
            // The bytes held for the bar belong to the transfer the user starts now.
            return [.hideOffer] + begin(kind, direction, at: now, byteClean: byteClean)
        case .choosingFiles, .idle:
            if case .idle = state {
                held = []
                remoteStarted = false
            }
            return begin(kind, direction, at: now, byteClean: byteClean)
        }
    }

    /// Call regularly while waiting (10 Hz): starts the session when BINARY is on or the wait is over.
    public mutating func tick(at now: Double, byteClean: Bool) -> [TransferCoordinatorAction] {
        guard case .negotiating(let kind, let direction, let deadline) = state else { return [] }
        if byteClean || now >= deadline { return start(kind, direction, byteClean: byteClean) }
        return []
    }

    /// The running session ended. After a cancel or failure the other side may still be
    /// draining what was in flight and then repeat its start (an rz sends ZRINIT again): such
    /// starts are drawn, not asked about, until the user types or `quietAfterAbort` passes.
    /// After a completed session nothing is quieted.
    public mutating func sessionFinished(at now: Double, succeeded: Bool = true) {
        reset()
        quietAfterAbortUntil = succeeded ? -.infinity : now + Self.quietAfterAbort
    }

    /// The user typed at the BBS: a start from now on is a new request, so it is asked about.
    public mutating func userTyped() {
        quietAfterAbortUntil = -.infinity
    }

    /// Escape or Cancel before the session exists: the bar is dismissed like Ignore; a pending
    /// start is abandoned and the BBS told to stop.
    public mutating func cancelPending(at now: Double) -> [TransferCoordinatorAction] {
        switch state {
        case .offering: return ignore(at: now)
        case .choosingFiles: return filesChosen(false, at: now, byteClean: false)
        case .negotiating:
            let tell = remoteStarted
            reset()
            return (tell ? [.sendToRemote(Self.cancelSequence)] : []) + [.endPending]
        case .idle, .running: return []
        }
    }

    /// The connection ended.
    public mutating func connectionClosed(at now: Double) -> [TransferCoordinatorAction] {
        let previous = state
        let release = held
        reset()
        switch previous {
        case .running: return [.failSession("the connection closed")]
        case .negotiating: return [.endPending]
        case .offering: return [.hideOffer] + (release.isEmpty ? [] : [.showOnScreen(release)])
        case .choosingFiles: return release.isEmpty ? [] : [.showOnScreen(release)]
        case .idle: return []
        }
    }

    // MARK: Private

    private mutating func begin(_ kind: TransferProtocolKind, _ direction: TransferDirection, at now: Double,
                                byteClean: Bool) -> [TransferCoordinatorAction] {
        if usesTelnet, !byteClean {
            state = .negotiating(kind, direction, deadline: now + Self.binaryWait)
            return [.requestBinary]
        }
        return start(kind, direction, byteClean: byteClean)
    }

    private mutating func start(_ kind: TransferProtocolKind, _ direction: TransferDirection,
                                byteClean: Bool) -> [TransferCoordinatorAction] {
        let warning = !byteClean && kind != .kermit ? TransferHelp.binaryWarning(for: kind) : nil
        let request = TransferRequest(kind: kind, direction: direction, initialBytes: held, byteClean: byteClean, warning: warning,
                                      fromBBS: remoteStarted)
        held = []
        detector.reset()
        state = .running
        return [.startSession(request)]
    }

    private mutating func reset() {
        state = .idle
        held = []
        remoteStarted = false
        detector.reset()
    }
}

/// Write side flow control for pull mode (ruling 4): at most `window` bytes handed to the
/// connection and not yet confirmed written, pulled in chunks of `chunk`.
public struct TransferFlow: Equatable, Sendable {
    public let window: Int
    public let chunk: Int
    public private(set) var inFlight = 0

    public init(window: Int = 256 * 1024, chunk: Int = 16 * 1024) {
        self.window = window
        self.chunk = chunk
    }

    /// How many bytes to pull now (0 while the window is full).
    public func nextChunkSize() -> Int { max(0, min(chunk, window - inFlight)) }
    public mutating func sent(_ count: Int) { inFlight += count }
    public mutating func completed(_ count: Int) { inFlight = max(0, inFlight - count) }
}
