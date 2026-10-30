import Foundation

/// Number and time text for the transfer panel (fixed format, no locale: the panel and the log
/// read the same everywhere).
public enum TransferText {
    /// 1048576 -> "1,048,576".
    public static func count(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return value < 0 ? "-" + out : out
    }

    /// Bytes per second: "500 B/s", "12.0 KB/s", "3.5 MB/s" (1024 based).
    public static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return "\(Int(bytesPerSecond.rounded())) B/s" }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSecond / 1024) }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
    }

    /// "0:42", "12:05", "1:02:05".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Everything the transfer panel shows while a session runs, as text (the view only lays it out).
public struct TransferPanelModel: Equatable {
    public let kind: TransferProtocolKind
    public let direction: TransferDirection
    /// Files being sent (unknown when receiving).
    public let fileCount: Int?
    /// Bytes of all files being sent (unknown when receiving).
    public let totalBytes: Int?
    public let zmodemBlockSize: Int
    public private(set) var progress: FileTransferSession.Progress?
    public private(set) var errors = 0
    public private(set) var resumeOffset: Int?
    public private(set) var negotiated: String?
    public var warning: String?

    public init(kind: TransferProtocolKind, direction: TransferDirection, fileCount: Int?, totalBytes: Int?,
                zmodemBlockSize: Int = 1024) {
        self.kind = kind
        self.direction = direction
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.zmodemBlockSize = zmodemBlockSize
    }

    public mutating func apply(_ progress: FileTransferSession.Progress) { self.progress = progress }

    public mutating func apply(_ event: TransferEvent) {
        switch event {
        case .recovered: errors += 1
        case .fileStarted(_, _, let offset): resumeOffset = offset > 0 ? offset : nil
        case .negotiated(let text): negotiated = text
        default: break
        }
    }

    public var title: String { "\(direction == .send ? "Sending" : "Receiving") with \(kind.displayName)" }
    public var fileName: String { progress?.fileName ?? "Waiting for the BBS..." }

    public var fileLine: String {
        let index = (progress?.filesCompleted ?? 0) + 1
        if let fileCount { return "File \(min(index, max(1, fileCount))) of \(fileCount)" }
        return "File \(index)"
    }

    public var bytesLine: String {
        let bytes = progress?.fileBytes ?? 0
        if let size = progress?.fileSize { return "\(TransferText.count(bytes)) of \(TransferText.count(size)) bytes" }
        return "\(TransferText.count(bytes)) bytes"
    }

    public var totalLine: String {
        let bytes = progress?.sessionBytes ?? 0
        if let totalBytes { return "\(TransferText.count(bytes)) of \(TransferText.count(totalBytes)) bytes in all" }
        return "\(TransferText.count(bytes)) bytes in all"
    }

    /// The current file's share done, when its size is known.
    public var fraction: Double? {
        guard let p = progress, let size = p.fileSize else { return nil }
        return size == 0 ? 1 : min(1, Double(p.fileBytes) / Double(size))
    }

    public var speedLine: String { TransferText.rate(progress?.bytesPerSecond ?? 0) }
    public var etaLine: String { progress?.eta.map(TransferText.duration) ?? "unknown" }
    public var errorsLine: String { "\(errors)" }
    public var resumeLine: String? { resumeOffset.map { "Resumed at \(TransferText.count($0)) bytes" } }

    public var blockLine: String {
        switch kind {
        case .xmodem, .xmodemCRC: return "128 bytes"
        case .xmodem1K: return "1024 bytes (128 near the end)"
        case .ymodem, .ymodemG: return "1024 bytes"
        case .zmodem: return direction == .send ? "\(zmodemBlockSize) byte subpackets" : "the sender's choice (up to 8192)"
        case .kermit: return negotiated ?? "negotiating"
        }
    }
}

/// The end of a session in words: the headline, one line per file and where files went.
public struct TransferSummary: Equatable {
    public var headline: String
    public var lines: [String]
    public var files: [TransferredFile]
    public var succeeded: Bool
    /// The folder of the received files (for Reveal in Finder).
    public var folder: URL?

    public init(outcome: FileTransferSession.Outcome, kind: TransferProtocolKind, direction: TransferDirection,
                elapsed: Double, bytes: Int) {
        switch outcome {
        case .completed(let files):
            self.files = files
            succeeded = true
            let verb = direction == .send ? "Sent" : "Received"
            let rate = elapsed > 0 ? " (\(TransferText.rate(Double(bytes) / elapsed)))" : ""
            headline = "\(verb) \(files.count) file\(files.count == 1 ? "" : "s"), \(TransferText.count(bytes)) bytes in "
                + "\(TransferText.duration(elapsed))\(rate) with \(kind.displayName)"
        case .failed(let reason):
            files = []
            succeeded = false
            headline = "Transfer failed: \(reason)"
        case .cancelled(let reason):
            files = []
            succeeded = false
            headline = "Transfer cancelled: \(reason)"
        }
        lines = files.map { file in
            "\(file.name): \(TransferText.count(file.bytes)) bytes, SHA-256 \(file.sha256)"
                + (file.resumedFrom > 0 ? ", resumed from \(TransferText.count(file.resumedFrom))" : "")
                + (file.isShort ? ", SHORT: \(TransferText.count(file.announcedSize ?? 0)) bytes were announced" : "")
        }
        folder = direction == .receive ? files.compactMap(\.url).first?.deletingLastPathComponent() : nil
    }
}

/// Per entry transfer logs (ruling 8): one text file per dialing directory entry, newest half
/// kept when it grows past `maxBytes`.
public struct TransferLogStore {
    public let directory: URL
    public let maxBytes: Int

    public init(directory: URL, maxBytes: Int = 1 << 20) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public func url(for entryID: UUID) -> URL { directory.appendingPathComponent("\(entryID.uuidString).log") }

    public func append(entryID: UUID, text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: entryID)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(Data(text.utf8))
        if data.count > maxBytes {
            var kept = data.suffix(maxBytes / 2)
            if let newline = kept.firstIndex(of: 0x0A) { kept = kept[(newline + 1)...] }
            data = Data(kept)
        }
        try data.write(to: url, options: .atomic)
    }

    public func read(entryID: UUID) -> String {
        (try? String(contentsOf: url(for: entryID), encoding: .utf8)) ?? ""
    }

    public static func header(entryName: String, kind: TransferProtocolKind, direction: TransferDirection, date: Date,
                              timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "=== \(formatter.string(from: date)) \(entryName): \(kind.displayName) \(direction == .send ? "send" : "receive")"
    }
}
