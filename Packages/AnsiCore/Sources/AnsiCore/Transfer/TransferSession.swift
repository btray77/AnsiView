import Foundation

/// One file transfer, as the terminal sees it: pick a protocol and a direction, feed it the
/// bytes that arrive from the line, send the bytes it produces, and watch progress, the event
/// log and the outcome. Transport agnostic: the caller owns the connection (and its telnet layer,
/// see `TelnetTransferChannel`).
///
/// Output can be pushed (`onOutput`, a bounded amount per call so a streaming sender cannot
/// flood memory) or pulled (`takeOutput(max:)`, for callers with write backpressure).
public final class FileTransferSession {
    public enum Outcome: Equatable, Sendable {
        case completed([TransferredFile])
        case failed(String)
        case cancelled(String)
    }

    public struct Progress: Equatable, Sendable {
        public var fileName: String?
        public var fileBytes: Int
        public var fileSize: Int?
        public var filesCompleted: Int
        public var sessionBytes: Int
        /// Average over the last few seconds.
        public var bytesPerSecond: Double
        /// Time left for the current file, when its size and the rate are known.
        public var eta: TimeInterval?
        public var elapsed: TimeInterval
    }

    public struct LogEntry: Equatable, Sendable {
        /// Seconds since the session started.
        public var time: TimeInterval
        public var event: TransferEvent
    }

    public let kind: TransferProtocolKind
    public let direction: TransferDirection
    public let engine: TransferEngine
    public let clock: TransferClock

    public var onOutput: (([UInt8]) -> Void)?
    public var onEvent: ((TransferEvent) -> Void)?
    public var onProgress: ((Progress) -> Void)?
    public var onFinish: ((Outcome) -> Void)?
    /// Most bytes handed to `onOutput` per call of `start`, `feed`, `tick` or `pump`.
    public var pushBudget = 64 * 1024
    /// Seconds between progress callbacks.
    public var progressInterval: TimeInterval = 0.25

    public private(set) var log: [LogEntry] = []
    public private(set) var outcome: Outcome?
    private var files: [TransferredFile] = []
    private var startTime: TimeInterval = 0
    private var samples: [(time: TimeInterval, bytes: Int)] = []
    private var lastProgressReport: TimeInterval = -.infinity
    private var lastProgress: Progress?

    public convenience init(sending files: [OutgoingFile], kind: TransferProtocolKind,
                            options: TransferOptions = TransferOptions(), clock: TransferClock = SystemTransferClock()) {
        self.init(engine: TransferEngineFactory.sender(kind: kind, files: files, clock: clock, options: options),
                  kind: kind, direction: .send, clock: clock)
    }

    public convenience init(receivingInto sink: TransferSink, kind: TransferProtocolKind,
                            options: TransferOptions = TransferOptions(), clock: TransferClock = SystemTransferClock(),
                            xmodemFileName: String = "download.bin") {
        self.init(engine: TransferEngineFactory.receiver(kind: kind, sink: sink, clock: clock, options: options,
                                                         xmodemFileName: xmodemFileName),
                  kind: kind, direction: .receive, clock: clock)
    }

    public init(engine: TransferEngine, kind: TransferProtocolKind, direction: TransferDirection, clock: TransferClock) {
        self.engine = engine
        self.kind = kind
        self.direction = direction
        self.clock = clock
    }

    public var isFinished: Bool { outcome != nil }

    public func start() {
        startTime = clock.now
        record(.log("\(kind.displayName) \(direction == .send ? "send" : "receive") started"))
        engine.start()
        pump()
    }

    /// Bytes from the line (after any telnet decoding).
    public func feed(_ bytes: [UInt8]) {
        engine.receive(bytes)
        pump()
    }

    /// Call regularly (10 Hz is plenty): fires protocol timeouts and progress callbacks.
    public func tick() {
        engine.tick()
        pump()
    }

    public func cancel(reason: String = "cancelled by user") {
        engine.cancel(reason: reason)
        pump()
    }

    /// Pulls bytes to send (for callers that do not set `onOutput`).
    public func takeOutput(max: Int = 64 * 1024) -> [UInt8] {
        let bytes = engine.takeOutput(max: max)
        collect()
        return bytes
    }

    /// Pushes pending output to `onOutput` (bounded by `pushBudget`) and collects events.
    public func pump() {
        if let onOutput {
            var budget = pushBudget
            while budget > 0 {
                let bytes = engine.takeOutput(max: min(budget, 16 * 1024))
                if bytes.isEmpty { break }
                budget -= bytes.count
                onOutput(bytes)
            }
        }
        collect()
    }

    /// The event log as text lines, for a transfer log window or file.
    public func logLines() -> [String] {
        log.map { entry in String(format: "%8.2f ", entry.time) + Self.describe(entry.event) }
    }

    public static func describe(_ event: TransferEvent) -> String {
        switch event {
        case .log(let text): return text
        case .negotiated(let text): return "negotiated: \(text)"
        case .fileStarted(let name, let size, let offset):
            return "file \(name)" + (size.map { " (\($0) bytes)" } ?? "") + (offset > 0 ? " resuming at \(offset)" : "")
        case .fileCompleted(let file):
            return "done \(file.name): \(file.bytes) bytes, sha256 \(file.sha256)"
                + (file.resumedFrom > 0 ? ", resumed from \(file.resumedFrom)" : "") + (file.url.map { ", saved as \($0.path)" } ?? "")
        case .fileSkipped(let name, let reason): return "skipped \(name): \(reason)"
        case .recovered(let text): return "recovered: \(text)"
        case .completed: return "transfer complete"
        case .failed(let reason): return "transfer failed: \(reason)"
        case .cancelled(let reason): return "transfer cancelled: \(reason)"
        }
    }

    public var progress: Progress {
        let now = clock.now
        let p = engine.progress
        var rate = 0.0
        if let first = samples.first, let last = samples.last, last.time > first.time {
            rate = Double(last.bytes - first.bytes) / (last.time - first.time)
        }
        var eta: TimeInterval?
        if let size = p.fileSize, rate > 0 { eta = Double(max(0, size - p.fileBytes)) / rate }
        return Progress(fileName: p.fileName, fileBytes: p.fileBytes, fileSize: p.fileSize, filesCompleted: p.filesCompleted,
                        sessionBytes: p.sessionBytes, bytesPerSecond: rate, eta: eta, elapsed: now - startTime)
    }

    private func record(_ event: TransferEvent) {
        log.append(LogEntry(time: clock.now - startTime, event: event))
        onEvent?(event)
    }

    private func collect() {
        for event in engine.takeEvents() {
            if case .fileCompleted(let file) = event { files.append(file) }
            record(event)
        }
        let now = clock.now
        samples.append((now, engine.progress.sessionBytes))
        while let first = samples.first, now - first.time > 5, samples.count > 2 { samples.removeFirst() }
        if outcome == nil, now - lastProgressReport >= progressInterval {
            let current = progress
            if current != lastProgress {
                lastProgressReport = now
                lastProgress = current
                onProgress?(current)
            }
        }
        if outcome == nil, engine.status.isFinished {
            switch engine.status {
            case .completed: outcome = .completed(files)
            case .failed(let reason): outcome = .failed(reason)
            case .cancelled: outcome = .cancelled(log.reversed().compactMap { if case .cancelled(let r) = $0.event { return r } else { return nil } }.first ?? "cancelled")
            default: break
            }
            onProgress?(progress)
            if let outcome { onFinish?(outcome) }
        }
    }
}

public enum TransferEngineFactory {
    public static func sender(kind: TransferProtocolKind, files: [OutgoingFile], clock: TransferClock,
                              options: TransferOptions = TransferOptions()) -> TransferEngine {
        switch kind {
        case .xmodem, .xmodemCRC, .xmodem1K, .ymodem, .ymodemG:
            return XModemSender(kind: kind, files: files, clock: clock, options: options)
        case .zmodem:
            return ZModemSender(files: files, clock: clock, options: options)
        case .kermit:
            return UnavailableEngine(kind: kind, clock: clock, options: options)
        }
    }

    public static func receiver(kind: TransferProtocolKind, sink: TransferSink, clock: TransferClock,
                                options: TransferOptions = TransferOptions(), xmodemFileName: String = "download.bin") -> TransferEngine {
        switch kind {
        case .xmodem, .xmodemCRC, .xmodem1K, .ymodem, .ymodemG:
            return XModemReceiver(kind: kind, sink: sink, clock: clock, options: options, xmodemFileName: xmodemFileName)
        case .zmodem:
            return ZModemReceiver(sink: sink, clock: clock, options: options)
        case .kermit:
            return UnavailableEngine(kind: kind, clock: clock, options: options)
        }
    }
}

final class UnavailableEngine: TransferEngine {
    let kind: TransferProtocolKind
    init(kind: TransferProtocolKind, clock: TransferClock, options: TransferOptions) {
        self.kind = kind
        super.init(clock: clock, options: options)
    }

    override func begin() { fail("\(kind.displayName) is not available", cancelRemote: false) }
}
