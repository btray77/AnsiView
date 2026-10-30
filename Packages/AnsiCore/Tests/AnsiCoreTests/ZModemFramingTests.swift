import Foundation
import Testing
@testable import AnsiCore

@Suite struct ZModemFramingTests {
    func decode(_ bytes: [UInt8], reader: ZReader = ZReader()) -> [ZToken] {
        var tokens: [ZToken] = []
        reader.feed(bytes) { tokens.append($0) }
        return tokens
    }

    @Test func hexHeadersMatchTheKnownStrings() {
        // The ZRQINIT every sz sends, and lrzsz rz's ZRINIT (CANFDX | CANOVIO | CANFC32).
        #expect(ZFrame.hexHeader(ZHeader(type: ZType.rqinit)) == Array("**\u{18}B00000000000000\r".utf8) + [0x8A, 0x11])
        #expect(ZFrame.hexHeader(ZHeader(type: ZType.rinit, flags: 0x23)) == Array("**\u{18}B0100000023be50\r".utf8) + [0x8A, 0x11])
        #expect(ZFrame.hexHeader(ZHeader(type: ZType.fin)).suffix(2) == [0x0D, 0x8A], "no XON after ZFIN")
        #expect(ZFrame.hexHeader(ZHeader(type: ZType.ack, position: 5)).suffix(2) == [0x0D, 0x8A], "no XON after ZACK")
    }

    @Test func binary32HeaderCRCMatchesZlib() {
        let header = ZHeader(type: ZType.data, position: 0x1234_5678)
        let bytes = ZFrame.binaryHeader(header, crc32: true, escaper: ZEscaper())
        // ZPAD ZDLE ZBIN32, then type, p0..p3, CRC-32 0x02bbb772 little endian (no byte needs escaping).
        #expect(bytes == [0x2A, 0x18, 0x43, 10, 0x78, 0x56, 0x34, 0x12, 0x72, 0xB7, 0xBB, 0x02])
    }

    @Test(arguments: [ZHeaderEncoding.hex, .bin16, .bin32])
    func headersRoundTrip(encoding: ZHeaderEncoding) {
        var rng = SeededRandom(4)
        for _ in 0..<200 {
            let header = ZHeader(type: UInt8(rng.next() % 20), bytes: rng.bytes(4))
            let wire: [UInt8]
            switch encoding {
            case .hex: wire = ZFrame.hexHeader(header)
            case .bin16: wire = ZFrame.binaryHeader(header, crc32: false, escaper: ZEscaper())
            case .bin32: wire = ZFrame.binaryHeader(header, crc32: true, escaper: ZEscaper(escapeControl: true))
            }
            let reader = ZReader()
            reader.expectsDataAfterHeaders = false
            #expect(decode(wire, reader: reader) == [.header(header, encoding)])
        }
    }

    @Test func positionAndFlagsUseTheRightBytes() {
        let header = ZHeader(type: ZType.rpos, position: 0x0102_0304)
        #expect(header.bytes == [4, 3, 2, 1])
        #expect(header.position == 0x0102_0304)
        let flags = ZHeader(type: ZType.file, f0: ZConversion.resume, f1: 2)
        #expect(flags.f0 == 3 && flags.f1 == 2 && flags.bytes[3] == 3 && flags.bytes[2] == 2)
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func subpacketsRoundTripEveryByte(escapeControl: Bool, escapeTelnet: Bool) {
        let data = TestData.everyByte
        let escaper = ZEscaper(escapeControl: escapeControl, escapeTelnet: escapeTelnet)
        for crc32 in [false, true] {
            for end in [ZEnd.crcE, ZEnd.crcG, ZEnd.crcQ, ZEnd.crcW] {
                var e = escaper
                let wire = ZFrame.subpacket(data, end: end, crc32: crc32, escaper: &e)
                let reader = ZReader()
                reader.beginData(crc32: crc32)
                #expect(decode(wire, reader: reader) == [.data(data, end: end)], "escctl \(escapeControl) telnet \(escapeTelnet) crc32 \(crc32)")
                // What must never appear raw on the line.
                var raw = Set<UInt8>([0x10, 0x11, 0x13, 0x90, 0x91, 0x93])
                if escapeControl { raw.formUnion((0..<32).map(UInt8.init) + (128..<160).map(UInt8.init)) }
                if escapeTelnet { raw.formUnion([0xFF, 0x0D, 0x8D]) }
                raw.remove(0x18)
                var index = 0
                var leaked: [UInt8] = []
                while index < wire.count {
                    if wire[index] == 0x18 { index += 2; continue }
                    if raw.contains(wire[index]) { leaked.append(wire[index]) }
                    index += 1
                }
                if end == ZEnd.crcW { leaked.removeAll { $0 == 0x11 } } // the XON lrzsz sends after ZCRCW
                #expect(leaked.isEmpty, "raw \(leaked) with escctl \(escapeControl) telnet \(escapeTelnet)")
            }
        }
    }

    @Test func crAfterAtSignIsEscaped() {
        var escaper = ZEscaper()
        let wire = ZFrame.subpacket([0x40, 0x0D, 0x41, 0x0D], end: ZEnd.crcE, crc32: false, escaper: &escaper)
        #expect(Array(wire.prefix(5)) == [0x40, 0x18, 0x4D, 0x41, 0x0D])
    }

    @Test func splitAtEveryByteMatchesWholeFeed() {
        var escaper = ZEscaper()
        let stream = ZFrame.hexHeader(ZHeader(type: ZType.rinit, flags: 0x23))
            + ZFrame.binaryHeader(ZHeader(type: ZType.data, position: 0), crc32: true, escaper: escaper)
            + ZFrame.subpacket(TestData.everyByte, end: ZEnd.crcG, crc32: true, escaper: &escaper)
            + ZFrame.subpacket([1, 2, 3], end: ZEnd.crcE, crc32: true, escaper: &escaper)
            + ZFrame.hexHeader(ZHeader(type: ZType.eof, position: TestData.everyByte.count + 3))
        let whole = decode(stream)
        #expect(whole.count == 5)
        for split in 1..<stream.count {
            let reader = ZReader()
            var tokens: [ZToken] = []
            reader.feed(Array(stream[..<split])) { tokens.append($0) }
            reader.feed(Array(stream[split...])) { tokens.append($0) }
            #expect(tokens == whole, "split at \(split)")
        }
    }

    @Test func fiveCANsCancelFourDoNot() {
        #expect(decode([0x41, 0x18, 0x18, 0x18, 0x18, 0x42]).contains(.cancel) == false)
        #expect(decode([0x41, 0x18, 0x18, 0x18, 0x18, 0x18, 0x08, 0x08]).contains(.cancel))
        let reader = ZReader()
        reader.beginData(crc32: false)
        #expect(decode([1, 2, 0x18, 0x18, 0x18, 0x18, 0x18], reader: reader).contains(.cancel), "also inside a subpacket")
    }

    @Test func badChecksAreReported() {
        var wire = ZFrame.hexHeader(ZHeader(type: ZType.rinit, flags: 0x23))
        wire[12] = UInt8(ascii: "f")
        #expect(decode(wire).first.map { if case .badHeader = $0 { return true } else { return false } } == true)
        var escaper = ZEscaper()
        var data = ZFrame.subpacket([5, 6, 7, 8], end: ZEnd.crcW, crc32: true, escaper: &escaper)
        data[1] ^= 1
        let reader = ZReader()
        reader.beginData(crc32: true)
        #expect(decode(data, reader: reader).first.map { if case .badData = $0 { return true } else { return false } } == true)
    }

    @Test func zrubAndFlowControlBytes() {
        let reader = ZReader()
        reader.beginData(crc32: false)
        let payload: [UInt8] = [0x7F, 0xFF, 0x41]
        let crc = CRC16XMODEM.checksum(payload + [ZEnd.crcE])
        // 0x7F as ZDLE l, 0xFF as ZDLE m, raw XON and XOFF dropped.
        let wire: [UInt8] = [0x18, 0x6C, 0x11, 0x18, 0x6D, 0x13, 0x41, 0x18, ZEnd.crcE, UInt8(crc >> 8), UInt8(crc & 0xFF)]
        #expect(decode(wire, reader: reader) == [.data(payload, end: ZEnd.crcE)])
    }

    @Test func oversizedSubpacketIsRejected() {
        let reader = ZReader()
        reader.beginData(crc32: false)
        let tokens = decode(Array(repeating: 0x41, count: ZReader.maxSubpacket + 10), reader: reader)
        #expect(tokens.first.map { if case .badData = $0 { return true } else { return false } } == true)
    }
}
