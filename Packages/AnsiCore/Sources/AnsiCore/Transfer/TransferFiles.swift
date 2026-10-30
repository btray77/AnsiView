import CryptoKit
import Darwin
import Foundation

public enum TransferHash {
    public static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ bytes: [UInt8]) -> String { hex(SHA256.hash(data: bytes)) }
}

/// Turning a name chosen by the other side into a safe file name.
public enum TransferFileName {
    /// Longest name in UTF-8 bytes (APFS allows 255; room is left for `-NN` and `.part`).
    public static let maxLength = 200
    static let fallback = "download"

    /// Name bytes from a packet: UTF-8 when valid, otherwise CP437 (DOS era BBS names).
    public static func decode(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        var text = String.UnicodeScalarView()
        for byte in bytes { text.append(CP437.unicode[Int(byte)]) }
        return String(text)
    }

    public static func sanitize(_ raw: String) -> String {
        // Only the last path component counts, whatever the sender's path syntax.
        var name = raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        name = name.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        name = name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let control = scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
                || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
            scalars.append(control ? "_" : scalar)
        }
        name = String(scalars)
        while let last = name.last, last == " " || last == "." { name.removeLast() }
        if name.first == "." {
            while name.first == "." { name.removeFirst() }
            name = name.isEmpty ? "" : "_" + name
        }
        while name.first == " " { name.removeFirst() }
        if name.isEmpty { return fallback }
        if isReservedDeviceName(name) { name = "_" + name }
        return capped(name)
    }

    static func isReservedDeviceName(_ name: String) -> Bool {
        let stem = name.split(separator: ".", maxSplits: 1).first.map { $0.uppercased() } ?? ""
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$"].contains(stem) { return true }
        if stem.count == 4, stem.hasPrefix("COM") || stem.hasPrefix("LPT"), let digit = stem.last, ("1"..."9").contains(digit) {
            return true
        }
        return false
    }

    static func capped(_ name: String) -> String {
        guard name.utf8.count > maxLength else { return name }
        // The extension is kept only when it is short in bytes (a single character can carry
        // hundreds of combining marks). Trimming works on whole characters, never past empty.
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, name[dot...].utf8.count <= 16 {
            ext = String(name[dot...])
        }
        var stem = String(name.dropLast(ext.count))
        while !stem.isEmpty, stem.utf8.count + ext.utf8.count > maxLength { stem.removeLast() }
        let result = stem + ext
        return result.isEmpty || result.utf8.count > maxLength || stem.isEmpty ? fallback : result
    }

    /// `name-1.ext`, `name-2.ext`, ... for the given attempt (0 returns the name itself).
    static func variant(_ name: String, _ attempt: Int) -> String {
        guard attempt > 0 else { return name }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[..<dot]) + "-\(attempt)" + String(name[dot...])
        }
        return name + "-\(attempt)"
    }
}

/// What the sender announced about a file it is about to send.
public struct FileOffer: Equatable, Sendable {
    public var name: String
    public var size: Int?
    public var modified: Date?
    public var mode: Int?
    /// The protocol asked to continue an earlier partial copy (ZMODEM ZCRESUM, or our resume option).
    public var resumeRequested: Bool

    public init(name: String, size: Int? = nil, modified: Date? = nil, mode: Int? = nil, resumeRequested: Bool = false) {
        self.name = name
        self.size = size
        self.modified = modified
        self.mode = mode
        self.resumeRequested = resumeRequested
    }
}

public enum SinkDecision: Equatable, Sendable {
    /// Receive the file starting at this offset (nonzero only when resuming).
    case accept(offset: Int)
    case skip(reason: String)
}

public enum TransferFileError: Error, Equatable, CustomStringConvertible {
    case tooLarge(limit: Int)
    case exceedsAnnounced(size: Int)
    case notOpen
    case io(String)

    public var description: String {
        switch self {
        case .tooLarge(let limit): return "file is larger than the \(limit) byte limit"
        case .exceedsAnnounced(let size): return "sender sent more than the announced \(size) bytes"
        case .notOpen: return "no file is open"
        case .io(let message): return message
        }
    }
}

/// Where received files go. An engine calls `open` once per offered file, `write` for each run
/// of good data in order, then `finish` or `abort`.
public protocol TransferSink: AnyObject {
    func open(_ offer: FileOffer) -> SinkDecision
    func write(_ bytes: [UInt8]) throws
    func finish() throws -> TransferredFile
    /// Ends an unfinished file. `resumable` says whether the protocol could continue it later.
    func abort(resumable: Bool)
}

/// The receiving file side for the app: every file lands inside one directory under a sanitized
/// name, partial data lives in `<name>.part` until the file is complete, nothing is overwritten,
/// sizes are limited, and each finished file reports its SHA-256.
public final class DownloadsDirectorySink: TransferSink {
    public struct Options: Sendable {
        public var maxFileSize = 4 << 30
        /// Keep the `.part` of a cancelled or failed transfer when the protocol can resume it.
        public var keepPartialForResume = false
        /// Allow resuming from a `.part` when the protocol asks.
        public var allowResume = true
        public init() {}
    }

    private struct Current {
        var fd: Int32
        var partURL: URL
        var name: String
        var remoteName: String
        var announced: Int?
        var written: Int
        var resumedFrom: Int
        var hasher: SHA256
    }

    /// Extended attribute set on every `.part` this sink creates.
    public static let partialMarker = "com.traynham.ansiview.partial"

    public let directory: URL
    public let options: Options
    public private(set) var completed: [TransferredFile] = []
    private var current: Current?

    public init(directory: URL, options: Options = Options()) {
        self.directory = directory.standardizedFileURL
        self.options = options
    }

    deinit { if current != nil { abort(resumable: false) } }

    public func open(_ offer: FileOffer) -> SinkDecision {
        if current != nil { abort(resumable: false) }
        let name = TransferFileName.sanitize(offer.name)
        if let size = offer.size, size > options.maxFileSize {
            return .skip(reason: "announced size \(size) is over the \(options.maxFileSize) byte limit")
        }
        if offer.size.map({ $0 < 0 }) == true { return .skip(reason: "negative size") }
        let part = directory.appendingPathComponent(name + ".part")
        if offer.resumeRequested, options.allowResume, let resumed = openForResume(part, name: name, offer: offer) {
            current = resumed
            return .accept(offset: resumed.resumedFrom)
        }
        for attempt in 0..<1000 {
            let candidate = directory.appendingPathComponent(TransferFileName.variant(name, attempt) + ".part")
            let fd = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd >= 0 {
                // Mark it as ours: only marked partials can be resumed later.
                _ = Self.partialMarker.withCString { fsetxattr(fd, $0, "1", 1, 0, 0) }
                current = Current(fd: fd, partURL: candidate, name: name, remoteName: offer.name, announced: offer.size,
                                  written: 0, resumedFrom: 0, hasher: SHA256())
                return .accept(offset: 0)
            }
            if errno != EEXIST { return .skip(reason: "cannot create \(candidate.lastPathComponent): \(String(cString: strerror(errno)))") }
        }
        return .skip(reason: "too many files named \(name)")
    }

    private func openForResume(_ part: URL, name: String, offer: FileOffer) -> Current? {
        var info = stat()
        guard lstat(part.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let existing = Int(info.st_size)
        guard existing > 0, offer.size.map({ existing < $0 }) ?? true, existing <= options.maxFileSize else { return nil }
        let fd = Darwin.open(part.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        // A .part that this sink did not create (a browser's download, the user's own file) is
        // never appended to, whatever the sender asks.
        var marker: UInt8 = 0
        var check = stat()
        guard Self.partialMarker.withCString({ fgetxattr(fd, $0, &marker, 1, 0, 0) }) == 1, marker == UInt8(ascii: "1"),
              fstat(fd, &check) == 0, (check.st_mode & S_IFMT) == S_IFREG, check.st_nlink == 1 else {
            close(fd)
            return nil
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var total = 0
        while total < existing {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Swift.min($0.count, existing - total), off_t(total)) }
            if n <= 0 { break }
            hasher.update(data: buffer[0..<n])
            total += n
        }
        guard total == existing, lseek(fd, off_t(existing), SEEK_SET) == off_t(existing) else {
            close(fd)
            return nil
        }
        return Current(fd: fd, partURL: part, name: name, remoteName: offer.name, announced: offer.size,
                       written: existing, resumedFrom: existing, hasher: hasher)
    }

    public func write(_ bytes: [UInt8]) throws {
        guard var file = current else { throw TransferFileError.notOpen }
        guard !bytes.isEmpty else { return }
        if file.written + bytes.count > options.maxFileSize { throw TransferFileError.tooLarge(limit: options.maxFileSize) }
        if let size = file.announced, file.written + bytes.count > size { throw TransferFileError.exceedsAnnounced(size: size) }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(file.fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw TransferFileError.io("write failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
        file.hasher.update(data: bytes)
        file.written += bytes.count
        current = file
    }

    public func finish() throws -> TransferredFile {
        guard let file = current else { throw TransferFileError.notOpen }
        current = nil
        close(file.fd)
        for attempt in 0..<1000 {
            let finalName = TransferFileName.variant(file.name, attempt)
            let target = directory.appendingPathComponent(finalName)
            if renamex_np(file.partURL.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                let result = TransferredFile(name: finalName, remoteName: file.remoteName, bytes: file.written,
                                             sha256: TransferHash.hex(file.hasher.finalize()), url: target,
                                             resumedFrom: file.resumedFrom, announcedSize: file.announced)
                completed.append(result)
                return result
            }
            if errno != EEXIST {
                let message = String(cString: strerror(errno))
                unlink(file.partURL.path)
                throw TransferFileError.io("cannot name \(finalName): \(message)")
            }
        }
        unlink(file.partURL.path)
        throw TransferFileError.io("too many files named \(file.name)")
    }

    public func abort(resumable: Bool) {
        guard let file = current else { return }
        current = nil
        close(file.fd)
        if !(resumable && options.keepPartialForResume && file.written > 0) { unlink(file.partURL.path) }
    }
}

/// A sink that keeps files in memory, with the same name and size rules; for tests and previews.
public final class MemoryTransferSink: TransferSink {
    public var maxFileSize: Int
    public private(set) var files: [(name: String, data: [UInt8])] = []
    public private(set) var offers: [FileOffer] = []
    public private(set) var aborted = 0
    /// Files whose name is listed here are refused.
    public var refuse: Set<String> = []
    /// Bytes already present per name, offered as a resume point when the protocol asks.
    public var partials: [String: [UInt8]] = [:]
    private var current: (name: String, remote: String, size: Int?, data: [UInt8], resumed: Int)?

    public init(maxFileSize: Int = 1 << 30) { self.maxFileSize = maxFileSize }

    public func open(_ offer: FileOffer) -> SinkDecision {
        offers.append(offer)
        let name = TransferFileName.sanitize(offer.name)
        if refuse.contains(name) { return .skip(reason: "refused") }
        if let size = offer.size, size > maxFileSize || size < 0 { return .skip(reason: "bad size") }
        if offer.resumeRequested, let part = partials[name], !part.isEmpty, offer.size.map({ part.count < $0 }) ?? true {
            current = (name, offer.name, offer.size, part, part.count)
            return .accept(offset: part.count)
        }
        current = (name, offer.name, offer.size, [], 0)
        return .accept(offset: 0)
    }

    public func write(_ bytes: [UInt8]) throws {
        guard current != nil else { throw TransferFileError.notOpen }
        if current!.data.count + bytes.count > maxFileSize { throw TransferFileError.tooLarge(limit: maxFileSize) }
        if let size = current!.size, current!.data.count + bytes.count > size { throw TransferFileError.exceedsAnnounced(size: size) }
        current!.data.append(contentsOf: bytes)
    }

    public func finish() throws -> TransferredFile {
        guard let file = current else { throw TransferFileError.notOpen }
        current = nil
        files.append((file.name, file.data))
        partials[file.name] = nil
        return TransferredFile(name: file.name, remoteName: file.remote, bytes: file.data.count,
                               sha256: TransferHash.sha256Hex(file.data), resumedFrom: file.resumed, announcedSize: file.size)
    }

    public func abort(resumable: Bool) {
        guard let file = current else { return }
        current = nil
        aborted += 1
        if resumable { partials[file.name] = file.data }
    }
}

/// A file to send: on disk (read lazily) or in memory.
public final class OutgoingFile {
    public let name: String
    public let size: Int
    public let modified: Date?
    /// Unix permission bits, when known.
    public let mode: Int?
    private let memory: [UInt8]?
    private let url: URL?
    private var handle: FileHandle?

    public init(name: String, data: [UInt8], modified: Date? = nil, mode: Int? = nil) {
        self.name = name
        self.size = data.count
        self.modified = modified
        self.mode = mode
        self.memory = data
        self.url = nil
    }

    public init(url: URL, name: String? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw TransferFileError.io("\(url.lastPathComponent) is not a regular file")
        }
        self.name = name ?? url.lastPathComponent
        self.size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        self.modified = attributes[.modificationDate] as? Date
        self.mode = (attributes[.posixPermissions] as? NSNumber).map { 0o100000 | $0.intValue }
        self.memory = nil
        self.url = url
    }

    deinit { try? handle?.close() }

    public func read(offset: Int, count: Int) throws -> [UInt8] {
        let end = Swift.min(size, offset + count)
        guard offset < end else { return [] }
        if let memory { return Array(memory[offset..<end]) }
        if handle == nil, let url { handle = try FileHandle(forReadingFrom: url) }
        guard let handle else { throw TransferFileError.notOpen }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: end - offset) ?? Data()
        return [UInt8](data)
    }

    /// Bytes hashed per `advanceHash()` step: engines take one step per call, so a large file is
    /// hashed alongside the transfer instead of in one blocking pass before it.
    public static let hashStep = 256 * 1024
    private var hasher = SHA256()
    public private(set) var hashedBytes = 0
    private var digest: String?

    /// Hashes the next step of the file (no-op once done).
    public func advanceHash() throws {
        guard digest == nil else { return }
        if hashedBytes < size {
            let chunk = try read(offset: hashedBytes, count: min(Self.hashStep, size - hashedBytes))
            guard !chunk.isEmpty else { throw TransferFileError.io("\(name) ended early") }
            hasher.update(data: chunk)
            hashedBytes += chunk.count
        }
        if hashedBytes >= size { digest = TransferHash.hex(hasher.finalize()) }
    }

    /// The SHA-256 of the whole file, finishing whatever steps are left.
    public func sha256() throws -> String {
        while digest == nil { try advanceHash() }
        return digest!
    }
}
