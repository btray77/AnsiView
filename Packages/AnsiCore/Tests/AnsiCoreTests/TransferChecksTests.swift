import Testing
@testable import AnsiCore

@Suite struct TransferChecksTests {
    let check = Array("123456789".utf8)

    @Test func crc16XmodemCheckValue() {
        #expect(CRC16XMODEM.checksum(check) == 0x31C3)
    }

    @Test func crc32CheckValue() {
        #expect(CRC32.checksum(check) == 0xCBF4_3926)
    }

    @Test func crc16KermitCheckValue() {
        #expect(CRC16Kermit.checksum(check) == 0x2189)
    }

    @Test func incrementalEqualsOneShot() {
        var a = CRC16XMODEM.initial
        var b = CRC32.initial
        for byte in check {
            a = CRC16XMODEM.update(a, [byte])
            b = CRC32.update(b, [byte])
        }
        #expect(a == 0x31C3)
        #expect(CRC32.finish(b) == 0xCBF4_3926)
    }

    @Test func crc16OfDataPlusCrcIsZero() {
        let crc = CRC16XMODEM.checksum(check)
        #expect(CRC16XMODEM.checksum(check + [UInt8(crc >> 8), UInt8(crc & 0xFF)]) == 0)
    }

    @Test func xmodemArithmeticChecksum() {
        let expected = UInt8(477 & 0xFF) // 0x31 + ... + 0x39 = 477
        #expect(TransferChecks.sum8(check) == expected)
        #expect(TransferChecks.sum8([0xFF, 0x02]) == 0x01)
    }

    @Test func kermitBlockChecks() {
        // Type 1: s + ((s & 192) >> 6) & 63, as a printable character.
        let s = check.reduce(0) { $0 + Int($1) }
        #expect(KermitCheck.compute(check, type: 1) == [UInt8(32 + ((s + ((s & 192) >> 6)) & 63))])
        // Type 2: twelve bit sum in two characters.
        #expect(KermitCheck.compute(check, type: 2) == [UInt8(32 + ((s >> 6) & 63)), UInt8(32 + (s & 63))])
        // Type 3: CRC-16/KERMIT in three characters.
        let crc = 0x2189
        #expect(KermitCheck.compute(check, type: 3) == [UInt8(32 + ((crc >> 12) & 15)), UInt8(32 + ((crc >> 6) & 63)), UInt8(32 + (crc & 63))])
    }
}
