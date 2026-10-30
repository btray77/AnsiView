/// CRC-16/XMODEM (poly 0x1021, init 0, not reflected): XMODEM-CRC, YMODEM and ZMODEM CRC-16.
public enum CRC16XMODEM {
    public static let initial: UInt16 = 0
    static let table: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        return crc
    }

    @inline(__always)
    public static func update(_ crc: UInt16, byte: UInt8) -> UInt16 {
        table[Int(UInt8(crc >> 8) ^ byte)] ^ (crc << 8)
    }

    public static func update<S: Sequence>(_ crc: UInt16, _ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc = crc
        for byte in bytes { crc = table[Int(UInt8(crc >> 8) ^ byte)] ^ (crc << 8) }
        return crc
    }

    public static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        update(initial, bytes)
    }
}

/// CRC-32 (IEEE 802.3, reflected, init and final xor 0xFFFFFFFF): ZMODEM CRC-32.
public enum CRC32 {
    public static let initial: UInt32 = 0xFFFF_FFFF
    static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    @inline(__always)
    public static func update(_ crc: UInt32, byte: UInt8) -> UInt32 {
        table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ (crc >> 8)
    }

    public static func update<S: Sequence>(_ crc: UInt32, _ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc = crc
        for byte in bytes { crc = table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ (crc >> 8) }
        return crc
    }

    public static func finish(_ crc: UInt32) -> UInt32 { ~crc }

    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        finish(update(initial, bytes))
    }
}

/// CRC-16/KERMIT (poly 0x1021 reflected as 0x8408, init 0): Kermit block check type 3.
public enum CRC16Kermit {
    static let table: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        return crc
    }

    public static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes { crc = table[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ (crc >> 8) }
        return crc
    }
}

public enum TransferChecks {
    /// The XMODEM arithmetic checksum: the sum of the data bytes modulo 256.
    public static func sum8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var sum: UInt8 = 0
        for byte in bytes { sum &+= byte }
        return sum
    }
}

/// Kermit block checks, as the printable characters that go on the wire.
public enum KermitCheck {
    /// Number of check characters for a block check type (1, 2 or 3).
    public static func length(_ type: Int) -> Int { max(1, min(3, type)) }

    public static func compute(_ bytes: [UInt8], type: Int) -> [UInt8] {
        switch type {
        case 2:
            let s = bytes.reduce(0) { $0 &+ Int($1) } & 0xFFF
            return [tochar((s >> 6) & 63), tochar(s & 63)]
        case 3:
            let crc = Int(CRC16Kermit.checksum(bytes))
            return [tochar((crc >> 12) & 15), tochar((crc >> 6) & 63), tochar(crc & 63)]
        default:
            let s = bytes.reduce(0) { $0 &+ Int($1) }
            return [tochar((s + ((s & 192) >> 6)) & 63)]
        }
    }

    @inline(__always) static func tochar(_ value: Int) -> UInt8 { UInt8(truncatingIfNeeded: value + 32) }
}
