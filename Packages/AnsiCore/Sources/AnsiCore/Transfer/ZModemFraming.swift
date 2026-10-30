/// ZMODEM frame types (Forsberg, "The ZMODEM Inter Application File Transfer Protocol", 1988).
public enum ZType {
    public static let rqinit: UInt8 = 0, rinit: UInt8 = 1, sinit: UInt8 = 2, ack: UInt8 = 3, file: UInt8 = 4
    public static let skip: UInt8 = 5, nak: UInt8 = 6, abort: UInt8 = 7, fin: UInt8 = 8, rpos: UInt8 = 9
    public static let data: UInt8 = 10, eof: UInt8 = 11, ferr: UInt8 = 12, crc: UInt8 = 13, challenge: UInt8 = 14
    public static let compl: UInt8 = 15, can: UInt8 = 16, freecnt: UInt8 = 17, command: UInt8 = 18, stderr: UInt8 = 19

    static let names = ["ZRQINIT", "ZRINIT", "ZSINIT", "ZACK", "ZFILE", "ZSKIP", "ZNAK", "ZABORT", "ZFIN", "ZRPOS",
                        "ZDATA", "ZEOF", "ZFERR", "ZCRC", "ZCHALLENGE", "ZCOMPL", "ZCAN", "ZFREECNT", "ZCOMMAND", "ZSTDERR"]
    public static func name(_ type: UInt8) -> String { Int(type) < names.count ? names[Int(type)] : "type \(type)" }
}

/// Data subpacket frame ends.
public enum ZEnd {
    /// End of frame, header follows, no response.
    public static let crcE: UInt8 = 0x68
    /// Frame continues nonstop.
    public static let crcG: UInt8 = 0x69
    /// Frame continues, ZACK expected.
    public static let crcQ: UInt8 = 0x6A
    /// End of frame, ZACK expected.
    public static let crcW: UInt8 = 0x6B
}

/// ZRINIT capability flags (ZF0).
public enum ZCapability {
    public static let canFullDuplex: UInt8 = 0x01, canOverlapIO: UInt8 = 0x02, canBreak: UInt8 = 0x04
    public static let canCrypt: UInt8 = 0x08, canLZW: UInt8 = 0x10, canCRC32: UInt8 = 0x20
    public static let escapeControl: UInt8 = 0x40, escape8: UInt8 = 0x80
}

/// ZFILE conversion option (ZF0).
public enum ZConversion {
    public static let binary: UInt8 = 1, newline: UInt8 = 2, resume: UInt8 = 3
}

enum ZByte {
    static let pad: UInt8 = 0x2A, dle: UInt8 = 0x18, bin: UInt8 = 0x41, hex: UInt8 = 0x42, bin32: UInt8 = 0x43
    static let rub0: UInt8 = 0x6C, rub1: UInt8 = 0x6D, xon: UInt8 = 0x11
    static func isFlowControl(_ byte: UInt8) -> Bool { byte == 0x11 || byte == 0x13 || byte == 0x91 || byte == 0x93 }
}

public enum ZHeaderEncoding: Equatable, Sendable { case hex, bin16, bin32 }

/// A ZMODEM header: the frame type and four bytes, read either as a little endian file position
/// (ZP0 to ZP3) or as flags (ZF3 is byte 0, ZF0 is byte 3).
public struct ZHeader: Equatable, Sendable {
    public var type: UInt8
    public var bytes: [UInt8]

    public init(type: UInt8, bytes: [UInt8] = [0, 0, 0, 0]) {
        self.type = type
        self.bytes = Array(bytes.prefix(4)) + Array(repeating: 0, count: max(0, 4 - bytes.count))
    }

    public init(type: UInt8, position: Int) {
        let p = UInt32(truncatingIfNeeded: position)
        self.init(type: type, bytes: [UInt8(p & 0xFF), UInt8((p >> 8) & 0xFF), UInt8((p >> 16) & 0xFF), UInt8(p >> 24)])
    }

    public init(type: UInt8, flags f0: UInt8) { self.init(type: type, bytes: [0, 0, 0, f0]) }

    public init(type: UInt8, f0: UInt8, f1: UInt8 = 0, f2: UInt8 = 0, f3: UInt8 = 0) {
        self.init(type: type, bytes: [f3, f2, f1, f0])
    }

    public var position: Int {
        Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    }

    public var f0: UInt8 { bytes[3] }
    public var f1: UInt8 { bytes[2] }
    public var f2: UInt8 { bytes[1] }
    public var f3: UInt8 { bytes[0] }

    var body: [UInt8] { [type] + bytes }
}

/// ZDLE escaping for everything sent after ZDLE framing: ZDLE itself, DLE, XON, XOFF and their
/// high bit forms always; CR after `@` (the Telenet network rule); every control character with
/// ESCCTL; CR and 0xFF too with `escapeTelnet`.
public struct ZEscaper {
    public let escapeControl: Bool
    public let escapeTelnet: Bool
    // 0 plain, 1 escape (xor 0x40), 2 escape after @, 3 ZRUB1.
    private let table: [UInt8]
    private var last: UInt8 = 0

    public init(escapeControl: Bool = false, escapeTelnet: Bool = false) {
        self.escapeControl = escapeControl
        self.escapeTelnet = escapeTelnet
        table = (0..<256).map { value -> UInt8 in
            let byte = UInt8(value)
            switch byte {
            case 0x18, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93, 0x98: return 1
            case 0x0D, 0x8D: return escapeTelnet || escapeControl ? 1 : 2
            case 0xFF: return escapeTelnet ? 3 : 0
            default: return escapeControl && byte & 0x60 == 0 ? 1 : 0
            }
        }
    }

    @inline(__always)
    public mutating func append(_ byte: UInt8, to out: inout [UInt8]) {
        switch table[Int(byte)] {
        case 0: out.append(byte)
        case 1: out.append(ZByte.dle); out.append(byte ^ 0x40)
        case 2:
            if last & 0x7F == 0x40 {
                out.append(ZByte.dle)
                out.append(byte ^ 0x40)
            } else {
                out.append(byte)
            }
        default: out.append(ZByte.dle); out.append(ZByte.rub1)
        }
        last = byte
    }

    public mutating func append<S: Sequence>(contentsOf bytes: S, to out: inout [UInt8]) where S.Element == UInt8 {
        for byte in bytes { append(byte, to: &out) }
    }
}

public enum ZFrame {
    static let hexDigits = Array("0123456789abcdef".utf8)

    /// `ZPAD ZPAD ZDLE ZHEX`, type and flags as lowercase hex, CRC-16, CR, LF with the high bit
    /// set, then XON (except after ZACK and ZFIN), exactly as lrzsz sends them.
    public static func hexHeader(_ header: ZHeader) -> [UInt8] {
        var out: [UInt8] = [ZByte.pad, ZByte.pad, ZByte.dle, ZByte.hex]
        let crc = CRC16XMODEM.checksum(header.body)
        for byte in header.body + [UInt8(crc >> 8), UInt8(crc & 0xFF)] {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 15)])
        }
        out += [0x0D, 0x8A]
        if header.type != ZType.fin, header.type != ZType.ack { out.append(ZByte.xon) }
        return out
    }

    public static func binaryHeader(_ header: ZHeader, crc32: Bool, escaper: ZEscaper) -> [UInt8] {
        var escaper = escaper
        var out: [UInt8] = [ZByte.pad, ZByte.dle, crc32 ? ZByte.bin32 : ZByte.bin]
        escaper.append(contentsOf: header.body, to: &out)
        if crc32 {
            let crc = CRC32.checksum(header.body)
            escaper.append(contentsOf: [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)], to: &out)
        } else {
            let crc = CRC16XMODEM.checksum(header.body)
            escaper.append(contentsOf: [UInt8(crc >> 8), UInt8(crc & 0xFF)], to: &out)
        }
        return out
    }

    /// A data subpacket: escaped data, ZDLE and the frame end, then the escaped CRC of the data
    /// and the frame end byte. ZCRCW is followed by XON, as lrzsz does.
    public static func subpacket(_ data: [UInt8], end: UInt8, crc32: Bool, escaper: inout ZEscaper) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 16 + 12)
        escaper.append(contentsOf: data, to: &out)
        out.append(ZByte.dle)
        out.append(end)
        if crc32 {
            let crc = CRC32.finish(CRC32.update(CRC32.update(CRC32.initial, data), [end]))
            escaper.append(contentsOf: [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)], to: &out)
        } else {
            let crc = CRC16XMODEM.update(CRC16XMODEM.update(0, data), [end])
            escaper.append(contentsOf: [UInt8(crc >> 8), UInt8(crc & 0xFF)], to: &out)
        }
        if end == ZEnd.crcW { out.append(ZByte.xon) }
        return out
    }
}

public enum ZToken: Equatable, Sendable {
    case header(ZHeader, ZHeaderEncoding)
    case badHeader(String)
    case data([UInt8], end: UInt8)
    case badData(String)
    /// Five or more consecutive CAN: the other side cancelled.
    case cancel
}

/// Decodes the ZMODEM byte stream into headers and data subpackets. Bytes outside frames are
/// skipped. State survives any split between feeds. After a header that carries data (ZFILE,
/// ZSINIT, ZDATA, ZCOMMAND, ZSTDERR) the reader reads subpackets until one ends with ZCRCE or
/// ZCRCW, or one is bad.
public final class ZReader {
    public static let maxSubpacket = 8192 + 1024
    public var expectsDataAfterHeaders = true

    private enum State { case scan, pad, padDLE, binHeader(crc32: Bool), hexHeader, data, crc }
    private enum Decoded { case byte(UInt8), end(UInt8), bad(UInt8) }

    private var state = State.scan
    private var escaped = false
    private var buffer: [UInt8] = []
    private var crcBytes: [UInt8] = []
    private var hexValues: [UInt8] = []
    private var cancelRun = 0
    private var dataCRC32 = false
    private var frameEnd: UInt8 = 0

    public init() {}

    public var readingData: Bool {
        switch state {
        case .data, .crc: return true
        default: return false
        }
    }

    public func beginData(crc32: Bool) {
        state = .data
        dataCRC32 = crc32
        buffer.removeAll(keepingCapacity: true)
        escaped = false
    }

    /// Stop reading subpackets and look for the next header.
    public func resetToHeaders() {
        state = .scan
        escaped = false
        buffer.removeAll(keepingCapacity: true)
    }

    private static let dataHeaders: Set<UInt8> = [ZType.file, ZType.sinit, ZType.data, ZType.command, ZType.stderr]

    public func feed(_ bytes: [UInt8], _ emit: (ZToken) -> Void) {
        for byte in bytes {
            if byte == ZByte.dle {
                cancelRun += 1
                if cancelRun >= 5 {
                    cancelRun = 0
                    resetToHeaders()
                    emit(.cancel)
                    continue
                }
            } else {
                cancelRun = 0
            }
            switch state {
            case .scan:
                if byte == ZByte.pad { state = .pad }
            case .pad:
                if byte == ZByte.dle { state = .padDLE } else if byte != ZByte.pad { state = .scan }
            case .padDLE:
                switch byte {
                case ZByte.bin, ZByte.bin32:
                    state = .binHeader(crc32: byte == ZByte.bin32)
                    buffer.removeAll(keepingCapacity: true)
                    escaped = false
                case ZByte.hex:
                    state = .hexHeader
                    hexValues.removeAll(keepingCapacity: true)
                case ZByte.dle:
                    break
                default:
                    state = byte == ZByte.pad ? .pad : .scan
                }
            case .binHeader(let crc32):
                guard let decoded = decode(byte) else { continue }
                guard case .byte(let value) = decoded else {
                    state = .scan
                    emit(.badHeader("bad escape in a binary header"))
                    continue
                }
                buffer.append(value)
                if buffer.count == 5 + (crc32 ? 4 : 2) { finishBinaryHeader(crc32: crc32, emit) }
            case .hexHeader:
                if let value = Self.hexValue(byte) {
                    hexValues.append(value)
                    if hexValues.count == 14 { finishHexHeader(emit) }
                } else {
                    state = byte == ZByte.pad ? .pad : .scan
                    emit(.badHeader("bad hex header"))
                }
            case .data:
                guard let decoded = decode(byte) else { continue }
                switch decoded {
                case .byte(let value):
                    buffer.append(value)
                    if buffer.count > Self.maxSubpacket {
                        resetToHeaders()
                        emit(.badData("subpacket longer than \(Self.maxSubpacket) bytes"))
                    }
                case .end(let end):
                    frameEnd = end
                    crcBytes.removeAll(keepingCapacity: true)
                    state = .crc
                case .bad(let value):
                    resetToHeaders()
                    emit(.badData(String(format: "bad escape 0x%02x in data", value)))
                }
            case .crc:
                guard let decoded = decode(byte) else { continue }
                guard case .byte(let value) = decoded else {
                    resetToHeaders()
                    emit(.badData("bad escape in a data CRC"))
                    continue
                }
                crcBytes.append(value)
                if crcBytes.count == (dataCRC32 ? 4 : 2) { finishSubpacket(emit) }
            }
        }
    }

    @inline(__always)
    private func decode(_ byte: UInt8) -> Decoded? {
        if escaped {
            if ZByte.isFlowControl(byte) || byte == ZByte.dle { return nil }
            escaped = false
            switch byte {
            case ZEnd.crcE...ZEnd.crcW: return .end(byte)
            case ZByte.rub0: return .byte(0x7F)
            case ZByte.rub1: return .byte(0xFF)
            default: return byte & 0x60 == 0x40 ? .byte(byte ^ 0x40) : .bad(byte)
            }
        }
        if byte == ZByte.dle {
            escaped = true
            return nil
        }
        if ZByte.isFlowControl(byte) { return nil }
        return .byte(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x61 + 10
        case 0x41...0x46: return byte - 0x41 + 10
        default: return nil
        }
    }

    private func finishBinaryHeader(crc32: Bool, _ emit: (ZToken) -> Void) {
        let body = Array(buffer[0..<5])
        let ok: Bool
        if crc32 {
            let crc = CRC32.checksum(body)
            ok = buffer[5] == UInt8(crc & 0xFF) && buffer[6] == UInt8((crc >> 8) & 0xFF)
                && buffer[7] == UInt8((crc >> 16) & 0xFF) && buffer[8] == UInt8(crc >> 24)
        } else {
            let crc = CRC16XMODEM.checksum(body)
            ok = buffer[5] == UInt8(crc >> 8) && buffer[6] == UInt8(crc & 0xFF)
        }
        state = .scan
        guard ok else {
            emit(.badHeader("binary header CRC error"))
            return
        }
        accept(ZHeader(type: body[0], bytes: Array(body[1...])), crc32 ? .bin32 : .bin16, emit)
    }

    private func finishHexHeader(_ emit: (ZToken) -> Void) {
        var body: [UInt8] = []
        for i in stride(from: 0, to: 14, by: 2) { body.append(hexValues[i] << 4 | hexValues[i + 1]) }
        state = .scan
        guard CRC16XMODEM.checksum(body) == 0 else {
            emit(.badHeader("hex header CRC error"))
            return
        }
        accept(ZHeader(type: body[0], bytes: Array(body[1..<5])), .hex, emit)
    }

    private func accept(_ header: ZHeader, _ encoding: ZHeaderEncoding, _ emit: (ZToken) -> Void) {
        if expectsDataAfterHeaders, Self.dataHeaders.contains(header.type) { beginData(crc32: encoding == .bin32) }
        emit(.header(header, encoding))
    }

    private func finishSubpacket(_ emit: (ZToken) -> Void) {
        let ok: Bool
        if dataCRC32 {
            let crc = CRC32.finish(CRC32.update(CRC32.update(CRC32.initial, buffer), [frameEnd]))
            ok = crcBytes == [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        } else {
            let crc = CRC16XMODEM.update(CRC16XMODEM.update(0, buffer), [frameEnd])
            ok = crcBytes == [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        }
        guard ok else {
            resetToHeaders()
            emit(.badData("data CRC error"))
            return
        }
        let data = buffer
        let end = frameEnd
        buffer.removeAll(keepingCapacity: true)
        if end == ZEnd.crcE || end == ZEnd.crcW { state = .scan } else { state = .data }
        emit(.data(data, end: end))
    }
}
