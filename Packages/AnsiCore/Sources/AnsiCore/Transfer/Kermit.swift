import Foundation

// Kermit, after Frank da Cruz, "Kermit Protocol Manual" (6th edition) and "Kermit, A File
// Transfer Protocol" (1987): packets, block checks 1 to 3, control, 8th bit and repeat prefixing,
// long packets, sliding windows and attribute packets.

@inline(__always) func tochar(_ value: Int) -> UInt8 { UInt8(truncatingIfNeeded: value + 32) }
@inline(__always) func unchar(_ byte: UInt8) -> Int { Int(byte) - 32 }

enum KType {
    static let send = UInt8(ascii: "S"), ack = UInt8(ascii: "Y"), nak = UInt8(ascii: "N"), file = UInt8(ascii: "F")
    static let attributes = UInt8(ascii: "A"), data = UInt8(ascii: "D"), eof = UInt8(ascii: "Z"), eot = UInt8(ascii: "B")
    static let error = UInt8(ascii: "E"), initialize = UInt8(ascii: "I"), text = UInt8(ascii: "X")
}

public struct KermitPacket: Equatable, Sendable {
    public var type: UInt8
    public var seq: Int
    public var data: [UInt8]

    public init(type: UInt8, seq: Int, data: [UInt8]) {
        self.type = type
        self.seq = seq & 63
        self.data = data
    }
}

public enum KermitCodec {
    public static let mark: UInt8 = 0x01
    public static let maxLongLength = 9024

    /// The block check used for a packet type: S and I packets always use type 1.
    static func checkType(for type: UInt8, current: Int) -> Int {
        type == KType.send || type == KType.initialize ? 1 : current
    }

    /// MARK, LEN, SEQ, TYPE, DATA, CHECK, CR. A packet that does not fit the 94 character basic
    /// length is sent long: LEN is 0, followed by LENX1, LENX2 and a header check.
    public static func encode(_ packet: KermitPacket, checkType: Int) -> [UInt8] {
        let check = Self.checkType(for: packet.type, current: checkType)
        let checkLength = KermitCheck.length(check)
        var body: [UInt8]
        if packet.data.count + 2 + checkLength <= 94 {
            body = [tochar(2 + packet.data.count + checkLength), tochar(packet.seq), packet.type]
        } else {
            let extended = packet.data.count + checkLength
            body = [tochar(0), tochar(packet.seq), packet.type, tochar(extended / 95), tochar(extended % 95)]
            let s = body.reduce(0) { $0 + Int($1) }
            body.append(tochar((s + ((s & 192) >> 6)) & 63))
        }
        body += packet.data
        return [mark] + body + KermitCheck.compute(body, type: check) + [0x0D]
    }
}

/// Splits the incoming stream into Kermit packets. A MARK anywhere starts a new packet; the
/// length field says where it ends.
public final class KermitReader {
    public enum Token: Equatable, Sendable {
        case packet(KermitPacket)
        case bad(String)
    }

    public var checkType = 1
    private enum State { case scan, length, normal(Int), longHeader, long(Int) }
    private var state = State.scan
    private var buffer: [UInt8] = []

    public init() {}

    public func feed(_ bytes: [UInt8], _ emit: (Token) -> Void) {
        for byte in bytes {
            if byte == KermitCodec.mark {
                state = .length
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            switch state {
            case .scan:
                continue
            case .length:
                buffer.append(byte)
                let n = unchar(byte)
                if n == 0 {
                    state = .longHeader
                } else if (3...94).contains(n) {
                    state = .normal(n)
                } else {
                    state = .scan
                    emit(.bad("bad length"))
                }
                continue
            default:
                break
            }
            // Control characters other than MARK may appear raw: C-Kermit leaves most of them
            // unprefixed by default ("cautious" prefixing). The length field delimits the packet.
            buffer.append(byte)
            switch state {
            case .normal(let need):
                if buffer.count == 1 + need { finish(headerLength: 3, emit) }
            case .longHeader:
                if buffer.count == 6 {
                    let s = buffer[0..<5].reduce(0) { $0 + Int($1) }
                    let extended = unchar(buffer[3]) * 95 + unchar(buffer[4])
                    if buffer[5] != tochar((s + ((s & 192) >> 6)) & 63) {
                        state = .scan
                        emit(.bad("long packet header check failed"))
                    } else if extended < 1 || extended > KermitCodec.maxLongLength + 3 {
                        state = .scan
                        emit(.bad("long packet length \(extended)"))
                    } else {
                        state = .long(extended)
                    }
                }
            case .long(let need):
                if buffer.count == 6 + need { finish(headerLength: 6, emit) }
            default:
                break
            }
        }
    }

    private func finish(headerLength: Int, _ emit: (Token) -> Void) {
        state = .scan
        let type = buffer[2]
        let seq = unchar(buffer[1])
        var candidates = [KermitCodec.checkType(for: type, current: checkType)]
        // An error packet may come before the check type switch took effect on the other side.
        if type == KType.error, checkType != 1 { candidates.append(1) }
        for check in candidates {
            let checkLength = KermitCheck.length(check)
            guard buffer.count - checkLength >= headerLength else { continue }
            let body = Array(buffer[0..<(buffer.count - checkLength)])
            if KermitCheck.compute(body, type: check) == Array(buffer[(buffer.count - checkLength)...]) {
                guard (0...63).contains(seq) else { break }
                emit(.packet(KermitPacket(type: type, seq: seq, data: Array(body[headerLength...]))))
                return
            }
        }
        emit(.bad("block check failed"))
    }
}

/// Control (`#`), 8th bit (`&`) and repeat count (`~`) prefixing of packet data fields.
public struct KermitQuoting: Equatable, Sendable {
    public var qctl: UInt8
    public var qbin: UInt8?
    public var rept: UInt8?

    public init(qctl: UInt8 = UInt8(ascii: "#"), qbin: UInt8? = nil, rept: UInt8? = nil) {
        self.qctl = qctl
        self.qbin = qbin
        self.rept = rept
    }

    @inline(__always)
    func append(_ byte: UInt8, to out: inout [UInt8]) {
        var c = byte
        if let qbin, c & 0x80 != 0 {
            out.append(qbin)
            c &= 0x7F
        }
        let low = c & 0x7F
        if low < 32 || low == 127 {
            out.append(qctl)
            out.append(c ^ 64)
        } else if low == qctl || (qbin != nil && low == qbin!) || (rept != nil && low == rept!) {
            out.append(qctl)
            out.append(c)
        } else {
            out.append(c)
        }
    }

    /// Encodes as much of `data` from `start` as fits in `budget` characters.
    public func encode(_ data: [UInt8], from start: Int, budget: Int) -> (bytes: [UInt8], consumed: Int) {
        var out: [UInt8] = []
        out.reserveCapacity(min(budget, (data.count - start) * 2 + 8))
        var index = start
        var piece: [UInt8] = []
        piece.reserveCapacity(8)
        while index < data.count {
            let byte = data[index]
            var run = 1
            if rept != nil {
                while index + run < data.count, data[index + run] == byte, run < 94 { run += 1 }
            }
            piece.removeAll(keepingCapacity: true)
            append(byte, to: &piece)
            var take = 1
            if let rept, run > 1, run * piece.count > piece.count + 2 {
                piece = [rept, tochar(run)] + piece
                take = run
            }
            if out.count + piece.count > budget { break }
            out += piece
            index += take
        }
        return (out, index - start)
    }

    public func encode(_ data: [UInt8]) -> [UInt8] { encode(data, from: 0, budget: Int.max).bytes }

    public func decode(_ data: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            var count = 1
            if let rept, data[i] == rept {
                guard i + 2 < data.count else { return nil }
                count = unchar(data[i + 1])
                guard count >= 0 else { return nil }
                i += 2
            }
            var bit8: UInt8 = 0
            if let qbin, data[i] == qbin {
                bit8 = 0x80
                i += 1
                guard i < data.count else { return nil }
            }
            var c = data[i]
            if c == qctl {
                i += 1
                guard i < data.count else { return nil }
                c = data[i]
                let low = c & 0x7F
                if (0o100...0o137).contains(low) || low == 0o77 { c ^= 64 }
            }
            c |= bit8
            for _ in 0..<count { out.append(c) }
            i += 1
        }
        return out
    }
}

/// The Send-Init (S) parameters, and the same fields in its ACK.
public struct KermitParameters: Equatable, Sendable {
    public var maxLength = 80
    public var timeout = 5
    public var npad = 0
    public var padc: UInt8 = 0
    public var eol: UInt8 = 13
    public var qctl = UInt8(ascii: "#")
    public var qbin = UInt8(ascii: "N")
    public var checkType = 1
    public var rept = UInt8(ascii: " ")
    public var longPackets = false
    public var slidingWindows = false
    public var attributes = false
    public var window = 1
    public var maxLongLength: Int?

    public init() {}

    public static func ours(_ options: TransferOptions) -> KermitParameters {
        var p = KermitParameters()
        let longest = min(KermitCodec.maxLongLength, max(20, options.kermitMaxPacket))
        p.maxLength = min(94, longest)
        p.timeout = max(1, min(94, Int(options.kermitTimeout)))
        p.qbin = options.kermitForceEighthBitPrefix ? UInt8(ascii: "&") : UInt8(ascii: "Y")
        p.checkType = max(1, min(3, options.kermitCheckType))
        p.rept = options.kermitUseRepeat ? UInt8(ascii: "~") : UInt8(ascii: " ")
        p.longPackets = longest > 94
        p.window = max(1, min(31, options.kermitWindow))
        p.slidingWindows = p.window > 1
        p.attributes = options.kermitUseAttributes
        p.maxLongLength = p.longPackets ? longest : nil
        return p
    }

    public func encoded() -> [UInt8] {
        let capas = (longPackets ? 2 : 0) | (slidingWindows ? 4 : 0) | (attributes ? 8 : 0)
        var out: [UInt8] = [tochar(maxLength), tochar(timeout), tochar(npad), padc ^ 64, tochar(Int(eol)), qctl, qbin,
                            UInt8(ascii: "0") + UInt8(checkType), rept, tochar(capas), tochar(window)]
        let long = maxLongLength ?? 500
        out += [tochar(long / 95), tochar(long % 95)]
        return out
    }

    public static func parse(_ data: [UInt8]) -> KermitParameters {
        var p = KermitParameters()
        func field(_ i: Int) -> UInt8? { i < data.count ? data[i] : nil }
        if let v = field(0) { p.maxLength = max(10, min(94, unchar(v))) }
        if let v = field(1) { p.timeout = max(0, unchar(v)) }
        if let v = field(2) { p.npad = max(0, unchar(v)) }
        if let v = field(3) { p.padc = v ^ 64 }
        if let v = field(4), unchar(v) > 0 { p.eol = UInt8(clamping: unchar(v)) }
        if let v = field(5), v != UInt8(ascii: " ") { p.qctl = v }
        if let v = field(6) { p.qbin = v }
        if let v = field(7), (UInt8(ascii: "1")...UInt8(ascii: "3")).contains(v) { p.checkType = Int(v - UInt8(ascii: "0")) }
        if let v = field(8) { p.rept = v }
        if let first = field(9) {
            let capas = unchar(first)
            p.longPackets = capas & 2 != 0
            p.slidingWindows = capas & 4 != 0
            p.attributes = capas & 8 != 0
            var last = 9
            while let v = field(last), unchar(v) & 1 != 0, last + 1 < data.count { last += 1 }
            if p.slidingWindows, let w = field(last + 1) { p.window = max(1, min(31, unchar(w))) }
            if p.longPackets {
                if let x1 = field(last + 2), let x2 = field(last + 3) {
                    p.maxLongLength = unchar(x1) * 95 + unchar(x2)
                } else {
                    p.maxLongLength = 500
                }
            }
        }
        return p
    }
}

/// What both sides agreed.
public struct KermitSettings: Equatable, Sendable {
    /// Longest packet (after MARK, through the check) the sender may send.
    public var sendLimit: Int
    /// Longest packet the receiver may send back.
    public var replyLimit: Int
    public var checkType: Int
    public var quoting: KermitQuoting
    public var window: Int
    public var attributes: Bool

    static func isPrefix(_ c: UInt8) -> Bool { (33...62).contains(c) || (96...126).contains(c) }

    public static func negotiate(sender: KermitParameters, receiver: KermitParameters, options: TransferOptions) -> KermitSettings {
        let long = sender.longPackets && receiver.longPackets
        func limit(to target: KermitParameters, from source: KermitParameters) -> Int {
            long ? min(target.maxLongLength ?? 500, source.maxLongLength ?? 500, KermitCodec.maxLongLength) : min(target.maxLength, 94)
        }
        var qbin: UInt8?
        if isPrefix(sender.qbin), receiver.qbin == UInt8(ascii: "Y") || receiver.qbin == sender.qbin {
            qbin = sender.qbin
        } else if sender.qbin == UInt8(ascii: "Y"), isPrefix(receiver.qbin) {
            qbin = receiver.qbin
        }
        let rept: UInt8? = sender.rept == receiver.rept && isPrefix(sender.rept) && sender.rept != sender.qctl ? sender.rept : nil
        return KermitSettings(sendLimit: limit(to: receiver, from: sender), replyLimit: limit(to: sender, from: receiver),
                              checkType: sender.checkType == receiver.checkType ? sender.checkType : 1,
                              quoting: KermitQuoting(qctl: sender.qctl, qbin: qbin, rept: rept),
                              window: sender.slidingWindows && receiver.slidingWindows ? max(1, min(sender.window, receiver.window)) : 1,
                              attributes: sender.attributes && receiver.attributes)
    }

    /// Data characters that fit one packet under `limit` with this check type.
    func dataBudget(_ limit: Int) -> Int {
        let check = KermitCheck.length(checkType)
        return limit <= 94 ? max(5, limit - 2 - check) : max(5, limit - 6 - check)
    }

    public var summary: String {
        var parts = ["block check \(checkType)", "packets up to \(sendLimit)", "window \(window)"]
        parts.append(quoting.qbin.map { "8th bit prefix \(Character(Unicode.Scalar($0)))" } ?? "no 8th bit prefix")
        parts.append(quoting.rept.map { "repeat prefix \(Character(Unicode.Scalar($0)))" } ?? "no repeat prefix")
        parts.append(attributes ? "attributes" : "no attributes")
        return parts.joined(separator: ", ")
    }
}

/// Attribute (A) packet fields: `1` exact length, `!` length in K, `#` date, `"` file type.
public enum KermitAttributes {
    public struct Info: Equatable, Sendable {
        public var size: Int?
        public var modified: Date?
        public var type: String?
    }

    static let dateFormats = ["yyyyMMdd HH:mm:ss", "yyyyMMdd HH:mm", "yyMMdd HH:mm:ss", "yyyyMMdd", "yyMMdd"]

    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }

    public static func encode(size: Int, modified: Date?) -> [UInt8] {
        func field(_ tag: Character, _ value: String) -> [UInt8] {
            [tag.asciiValue!, tochar(value.utf8.count)] + Array(value.utf8)
        }
        var out = field("\"", "B8") + field("1", String(size)) + field("!", String((size + 1023) / 1024))
        if let modified { out += field("#", formatter(dateFormats[0]).string(from: modified)) }
        return out
    }

    public static func parse(_ data: [UInt8]) -> Info {
        var info = Info()
        var kilobytes: Int?
        var i = 0
        while i + 1 < data.count {
            let tag = data[i]
            let length = max(0, unchar(data[i + 1]))
            let end = min(data.count, i + 2 + length)
            let value = String(decoding: data[(i + 2)..<end], as: UTF8.self)
            switch tag {
            case UInt8(ascii: "1"): info.size = Int(value).flatMap { $0 >= 0 ? $0 : nil }
            case UInt8(ascii: "!"): kilobytes = Int(value).flatMap { $0 >= 0 ? $0 : nil }
            case UInt8(ascii: "\""): info.type = value
            case UInt8(ascii: "#"):
                for format in dateFormats {
                    if let date = formatter(format).date(from: value) {
                        info.modified = date
                        break
                    }
                }
            default: break
            }
            i = end
        }
        if info.size == nil, let kilobytes {
            // A hostile value must not overflow; Int.max is refused by any size limit.
            let bytes = kilobytes.multipliedReportingOverflow(by: 1024)
            info.size = bytes.overflow ? Int.max : bytes.partialValue
        }
        return info
    }
}

/// Sends files with Kermit.
public final class KermitSender: TransferEngine {
    let files: [OutgoingFile]

    private enum Phase { case sendInit, fileHeader, attributes, data, eof, endOfTransmission }
    private struct Slot {
        var seq: Int
        var bytes: [UInt8]
        var count: Int
        var acked = false
        var retries = 0
    }

    private var phase = Phase.sendInit
    private let reader = KermitReader()
    private let local: KermitParameters
    private var settings: KermitSettings
    private var nextSeq = 0
    private var current: (seq: Int, bytes: [UInt8])?
    private var sentAt: TimeInterval = 0
    private var window: [Slot] = []
    private var fileIndex = 0
    private var position = 0
    private var acknowledged = 0
    private var retries = 0
    private var skipFile = false
    /// Data characters per new packet: halved after a retransmission, doubled back after clean ACKs.
    private var packetBudget = 0
    private var cleanAcks = 0

    public override var protocolName: String { "Kermit" }

    public init(files: [OutgoingFile], clock: TransferClock, options: TransferOptions = TransferOptions()) {
        self.files = files
        local = KermitParameters.ours(options)
        settings = KermitSettings.negotiate(sender: local, receiver: KermitParameters(), options: options)
        super.init(clock: clock, options: options)
    }

    private var file: OutgoingFile { files[fileIndex] }

    override func begin() {
        sendNew(KType.send, local.encoded())
    }

    override func cancelSequence() -> [UInt8] {
        KermitCodec.encode(KermitPacket(type: KType.error, seq: nextSeq, data: settings.quoting.encode(Array("cancelled".utf8))),
                           checkType: settings.checkType)
    }

    private func sendNew(_ type: UInt8, _ data: [UInt8]) {
        let bytes = KermitCodec.encode(KermitPacket(type: type, seq: nextSeq, data: data), checkType: settings.checkType)
        current = (nextSeq, bytes)
        nextSeq = (nextSeq + 1) & 63
        retries = 0
        sentAt = clock.now
        send(bytes)
        arm(options.kermitTimeout)
    }

    private func resendCurrent(_ reason: String) {
        guard let current else { return }
        retries += 1
        if retries > options.maxRetries {
            fail("too many retries (\(reason))")
            return
        }
        emit(.recovered(reason))
        sentAt = clock.now
        send(current.bytes)
        arm(options.kermitTimeout)
    }

    override func handle(_ bytes: [UInt8]) {
        var tokens: [KermitReader.Token] = []
        reader.feed(bytes) { tokens.append($0) }
        for token in tokens where status == .running {
            switch token {
            case .bad(let reason):
                // A damaged reply counts as a NAK of what is outstanding.
                if phase == .data { resendOldest("damaged reply: \(reason)") } else if phase != .sendInit { resendCurrent("damaged reply: \(reason)") }
            case .packet(let packet):
                switch packet.type {
                case KType.error:
                    let text = String(decoding: settings.quoting.decode(packet.data) ?? packet.data, as: UTF8.self)
                    fail("the receiver stopped: \(text)", cancelRemote: false)
                case KType.ack:
                    handleAck(packet)
                case KType.nak:
                    handleNak(packet)
                default:
                    break
                }
            }
        }
    }

    private func handleAck(_ packet: KermitPacket) {
        if phase == .data {
            if let index = window.firstIndex(where: { $0.seq == packet.seq && !$0.acked }) {
                window[index].acked = true
                if let first = packet.data.first, first == UInt8(ascii: "X") || first == UInt8(ascii: "Z") {
                    skipFile = true
                    emit(.fileSkipped(name: file.name, reason: "the receiver interrupted it"))
                }
                slide()
            }
            return
        }
        guard let current, packet.seq == current.seq else { return }
        disarm()
        switch phase {
        case .sendInit:
            let remote = KermitParameters.parse(packet.data)
            settings = KermitSettings.negotiate(sender: local, receiver: remote, options: options)
            reader.checkType = settings.checkType
            packetBudget = settings.dataBudget(settings.sendLimit)
            emit(.negotiated(settings.summary))
            startFile()
        case .fileHeader:
            if settings.attributes {
                phase = .attributes
                // Attribute data goes unprefixed: it is printable, and C-Kermit reads it raw.
                sendNew(KType.attributes, KermitAttributes.encode(size: file.size, modified: file.modified))
            } else {
                startData()
            }
        case .attributes:
            let reply = settings.quoting.decode(packet.data) ?? packet.data
            if reply.first == UInt8(ascii: "N") {
                skipFile = true
                emit(.fileSkipped(name: file.name, reason: "the receiver refused it (\(String(decoding: reply.dropFirst(), as: UTF8.self)))"))
                sendEOF()
            } else {
                startData()
            }
        case .eof:
            if !skipFile {
                emit(.fileCompleted(TransferredFile(name: file.name, remoteName: file.name, bytes: file.size, sha256: finalHash(file))))
                progress.filesCompleted += 1
            }
            fileIndex += 1
            startFile()
        case .endOfTransmission:
            complete()
        case .data:
            break
        }
    }

    private func handleNak(_ packet: KermitPacket) {
        if phase == .data {
            if let index = window.firstIndex(where: { $0.seq == packet.seq }) {
                resend(slot: index, "NAK \(packet.seq)")
            } else if packet.seq == nextSeq {
                // A NAK for the next new packet acknowledges everything outstanding.
                for i in window.indices { window[i].acked = true }
                slide()
            }
            return
        }
        guard let current else { return }
        if packet.seq == current.seq {
            // A NAK that crossed our packet on the line (C-Kermit NAKs at once when it starts).
            if phase == .sendInit, clock.now - sentAt < 1 { return }
            resendCurrent("NAK \(packet.seq)")
        } else if packet.seq == (current.seq + 1) & 63, phase != .sendInit {
            handleAck(KermitPacket(type: KType.ack, seq: current.seq, data: []))
        }
    }

    private func startFile() {
        guard fileIndex < files.count else {
            phase = .endOfTransmission
            sendNew(KType.eot, [])
            return
        }
        hashingFile = file
        skipFile = false
        position = 0
        acknowledged = 0
        progress.fileName = file.name
        progress.fileSize = file.size
        progress.fileBytes = 0
        emit(.fileStarted(name: file.name, size: file.size, offset: 0))
        phase = .fileHeader
        let name = settings.quoting.encode(Array(file.name.utf8), from: 0, budget: settings.dataBudget(settings.sendLimit)).bytes
        sendNew(KType.file, name)
    }

    private func startData() {
        phase = .data
        window.removeAll()
        disarm()
    }

    private func sendEOF() {
        phase = .eof
        sendNew(KType.eof, skipFile ? [UInt8(ascii: "D")] : [])
    }

    override func refill(_ budget: Int) {
        guard phase == .data, status == .running else { return }
        var produced = 0
        let dataBudget = max(5, min(packetBudget, settings.dataBudget(settings.sendLimit)))
        while window.count < settings.window, !skipFile, position < file.size, produced < budget {
            let raw: [UInt8]
            do { raw = try file.read(offset: position, count: min(file.size - position, dataBudget * 4)) } catch {
                fail("cannot read \(file.name): \(error)")
                return
            }
            let piece = settings.quoting.encode(raw, from: 0, budget: dataBudget)
            guard piece.consumed > 0 else {
                fail("packet too small to carry data")
                return
            }
            let bytes = KermitCodec.encode(KermitPacket(type: KType.data, seq: nextSeq, data: piece.bytes), checkType: settings.checkType)
            if window.isEmpty { arm(options.kermitTimeout) }
            window.append(Slot(seq: nextSeq, bytes: bytes, count: piece.consumed))
            nextSeq = (nextSeq + 1) & 63
            send(bytes)
            produced += bytes.count
            position += piece.consumed
            progress.fileBytes = position
        }
        if window.isEmpty, skipFile || position >= file.size { sendEOF() }
    }

    private func slide() {
        while let first = window.first, first.acked {
            if first.retries == 0 {
                cleanAcks += 1
                let full = settings.dataBudget(settings.sendLimit)
                if cleanAcks >= 8, packetBudget < full {
                    packetBudget = min(full, packetBudget * 2)
                    cleanAcks = 0
                }
            }
            acknowledged += first.count
            progress.sessionBytes += first.count
            window.removeFirst()
        }
        if window.isEmpty {
            disarm()
            if skipFile || position >= file.size { sendEOF() }
        } else {
            arm(options.kermitTimeout)
        }
    }

    private func resend(slot index: Int, _ reason: String) {
        window[index].retries += 1
        if window[index].retries > options.maxRetries {
            fail("too many retries (\(reason))")
            return
        }
        emit(.recovered(reason))
        send(window[index].bytes)
        arm(options.kermitTimeout)
        // A noisy line: make new packets shorter so fewer of them are hit.
        cleanAcks = 0
        packetBudget = max(min(90, settings.dataBudget(settings.sendLimit)), packetBudget / 2)
    }

    private func resendOldest(_ reason: String) {
        if let index = window.firstIndex(where: { !$0.acked }) { resend(slot: index, reason) }
    }

    override func timedOut() {
        if phase == .data {
            resendOldest("timeout")
        } else {
            resendCurrent("timeout")
        }
    }
}

/// Receives files with Kermit.
public final class KermitReceiver: TransferEngine {
    let sink: TransferSink

    private enum Phase { case waitInit, transfer }
    private var phase = Phase.waitInit
    private let reader = KermitReader()
    private let local: KermitParameters
    private var settings: KermitSettings
    private var expected = 0
    private var buffered: [Int: KermitPacket] = [:]
    private var nakked: Set<Int> = []
    private var acks: [Int: [UInt8]] = [:]
    private var sendInitAck: [UInt8] = []
    private var retries = 0
    private var fileName: String?
    private var fileOpen = false
    private var skipping = false
    private var announcedSize: Int?
    private var received = 0

    public override var protocolName: String { "Kermit" }

    public init(sink: TransferSink, clock: TransferClock, options: TransferOptions = TransferOptions()) {
        self.sink = sink
        local = KermitParameters.ours(options)
        settings = KermitSettings.negotiate(sender: KermitParameters(), receiver: local, options: options)
        super.init(clock: clock, options: options)
    }

    override func begin() {
        send(KermitCodec.encode(KermitPacket(type: KType.nak, seq: 0, data: []), checkType: 1))
        arm(options.kermitTimeout)
    }

    override func cancelSequence() -> [UInt8] {
        KermitCodec.encode(KermitPacket(type: KType.error, seq: expected, data: settings.quoting.encode(Array("cancelled".utf8))),
                           checkType: phase == .waitInit ? 1 : settings.checkType)
    }

    private func reply(_ type: UInt8, _ seq: Int, _ data: [UInt8] = []) -> [UInt8] {
        let bytes = KermitCodec.encode(KermitPacket(type: type, seq: seq, data: data), checkType: settings.checkType)
        send(bytes)
        return bytes
    }

    override func handle(_ bytes: [UInt8]) {
        var tokens: [KermitReader.Token] = []
        reader.feed(bytes) { tokens.append($0) }
        for token in tokens where status == .running {
            switch token {
            case .bad:
                if phase == .transfer, buffered.isEmpty {
                    _ = reply(KType.nak, expected)
                } else if phase == .waitInit {
                    send(KermitCodec.encode(KermitPacket(type: KType.nak, seq: 0, data: []), checkType: 1))
                }
            case .packet(let packet):
                if packet.type == KType.error {
                    let text = String(decoding: settings.quoting.decode(packet.data) ?? packet.data, as: UTF8.self)
                    fail("the sender stopped: \(text)", cancelRemote: false)
                } else if packet.type == KType.send || packet.type == KType.initialize {
                    handleSendInit(packet)
                } else if phase == .transfer {
                    handleSequenced(packet)
                }
            }
        }
    }

    private func handleSendInit(_ packet: KermitPacket) {
        if phase == .waitInit {
            let remote = KermitParameters.parse(packet.data)
            // The receiver agrees to the sender's block check when it supports it (all three
            // here), as C-Kermit does; answering with a different type would make the two
            // sides disagree (the sender then uses its own type, not type 1).
            var answer = local
            answer.checkType = remote.checkType
            settings = KermitSettings.negotiate(sender: remote, receiver: answer, options: options)
            sendInitAck = KermitCodec.encode(KermitPacket(type: KType.ack, seq: packet.seq, data: answer.encoded()), checkType: 1)
            reader.checkType = settings.checkType
            expected = (packet.seq + 1) & 63
            phase = .transfer
            retries = 0
            emit(.negotiated(settings.summary))
        }
        // Also answers a repeated S (our ACK was lost).
        send(sendInitAck)
        arm(options.kermitTimeout)
    }

    private func handleSequenced(_ packet: KermitPacket) {
        let ahead = (packet.seq - expected + 64) & 63
        if ahead == 0 {
            process(packet)
            while status == .running, let next = buffered.removeValue(forKey: expected) { process(next) }
        } else if ahead < settings.window, packet.type == KType.data {
            if buffered[packet.seq] == nil {
                buffered[packet.seq] = packet
                emit(.recovered("packet \(packet.seq) ahead of \(expected)"))
            }
            acks[packet.seq] = reply(KType.ack, packet.seq)
            // Ask again for the ones missing before it.
            var seq = expected
            while seq != packet.seq {
                if buffered[seq] == nil, !nakked.contains(seq) {
                    nakked.insert(seq)
                    _ = reply(KType.nak, seq)
                }
                seq = (seq + 1) & 63
            }
            arm(options.kermitTimeout)
        } else if ahead >= 64 - max(settings.window, 1) - 1, let ack = acks[packet.seq] {
            // Already have it: the ACK was lost. A peer repeating it forever is a failure.
            retries += 1
            if retries > options.maxRetries + settings.window {
                fail("packet \(packet.seq) repeated too often")
                return
            }
            emit(.recovered("duplicate packet \(packet.seq)"))
            send(ack)
            arm(options.kermitTimeout)
        }
    }

    private func process(_ packet: KermitPacket) {
        var ackData: [UInt8] = []
        let data = settings.quoting.decode(packet.data)
        switch packet.type {
        case KType.file:
            guard let name = data else { return protocolError("unreadable file name") }
            abortUnfinished()
            fileName = TransferFileName.decode(name)
            announcedSize = nil
            skipping = false
            fileOpen = false
            received = 0
        case KType.attributes:
            // Read raw, as C-Kermit sends it (its date tag `#` is the control prefix character).
            let info = KermitAttributes.parse(packet.data)
            if !openFile(size: info.size, modified: info.modified) { ackData = Array("N1".utf8) } else { ackData = [UInt8(ascii: "Y")] }
        case KType.data:
            guard let bytes = data else { return protocolError("unreadable data") }
            if !fileOpen, !skipping, !openFile(size: nil, modified: nil) { ackData = [UInt8(ascii: "X")] }
            if fileOpen, !skipping {
                do { try sink.write(bytes) } catch {
                    fail("\(error)")
                    return
                }
            }
            received += bytes.count
            progress.fileBytes = received
            progress.sessionBytes += bytes.count
        case KType.eof:
            if data == [UInt8(ascii: "D")] {
                if fileOpen { sink.abort(resumable: false) }
                if fileOpen || !skipping { emit(.fileSkipped(name: fileName ?? "?", reason: "the sender discarded it")) }
                fileOpen = false
            } else {
                if !fileOpen, !skipping { _ = openFile(size: nil, modified: nil) }
                if fileOpen {
                    fileOpen = false
                    if let size = announcedSize, size != received { emit(.log("\(fileName ?? "?") ended at \(received), announced \(size)")) }
                    do {
                        let file = try sink.finish()
                        progress.filesCompleted += 1
                        emit(.fileCompleted(file))
                    } catch {
                        fail("\(error)")
                        return
                    }
                }
            }
            skipping = false
            fileName = nil
        case KType.eot:
            abortUnfinished()
            acks[packet.seq] = reply(KType.ack, packet.seq)
            complete()
            return
        default:
            break
        }
        acks[packet.seq] = reply(KType.ack, packet.seq, settings.quoting.encode(ackData))
        nakked.remove(packet.seq)
        expected = (packet.seq + 1) & 63
        // Forget ACKs that can no longer be asked for again.
        acks[(expected + 31) & 63] = nil
        retries = 0
        arm(options.kermitTimeout)
    }

    private func openFile(size: Int?, modified: Date?) -> Bool {
        guard let name = fileName else { return false }
        announcedSize = size
        progress.fileName = name
        progress.fileSize = size
        progress.fileBytes = 0
        switch sink.open(FileOffer(name: name, size: size, modified: modified)) {
        case .accept:
            fileOpen = true
            emit(.fileStarted(name: name, size: size, offset: 0))
            return true
        case .skip(let reason):
            skipping = true
            emit(.fileSkipped(name: name, reason: reason))
            return false
        }
    }

    /// A file that never got its Z packet is not kept.
    private func abortUnfinished() {
        guard fileOpen else { return }
        sink.abort(resumable: false)
        fileOpen = false
        emit(.fileSkipped(name: fileName ?? "?", reason: "the sender moved on before the end of the file"))
    }

    private func protocolError(_ message: String) {
        fail(message)
    }

    override func abortCurrentFile() {
        if fileOpen { sink.abort(resumable: false) }
        fileOpen = false
    }

    override func timedOut() {
        retries += 1
        if retries > options.maxRetries {
            fail(phase == .waitInit ? "no Kermit sender answered" : "the sender stopped sending")
            return
        }
        emit(.recovered("timeout"))
        if phase == .waitInit {
            send(KermitCodec.encode(KermitPacket(type: KType.nak, seq: 0, data: []), checkType: 1))
        } else {
            _ = reply(KType.nak, expected)
        }
        arm(options.kermitTimeout)
    }
}
