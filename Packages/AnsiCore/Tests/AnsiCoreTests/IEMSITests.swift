import Foundation
import Testing
@testable import AnsiCore

@Test func iemsiCRC32IsTheUninvertedZmodemCRC() {
    // zlib's CRC-32 of "123456789" is CBF43926; EMSI keeps the register uninverted: its complement.
    #expect(IEMSI.crc32(Array("123456789".utf8)) == 0x340B_C6D9)
    #expect(IEMSI.crc16(Array("EMSI_IRQ".utf8)) == 0x8E08)
    #expect(IEMSI.crc16(Array("EMSI_ACK".utf8)) == 0xA490)
}

@Test func iemsiFieldEscaping() {
    #expect(IEMSI.field("a}b\\c\u{1}é") == Array("{a}}b\\5Cc\\01\\E9}".utf8))
}

@Test func iemsiICIPacket() {
    let info = IEMSI.Login(name: "JOHN DOE", password: "secret", rows: 24, columns: 80, emulation: "ANSI")
    let packet = String(decoding: IEMSI.ici(info), as: UTF8.self)
    #expect(packet.hasPrefix("**EMSI_ICI"))
    #expect(packet.hasSuffix("\r"))
    let body = String(packet.dropFirst(2).dropLast(9))   // from EMSI_ICI to before the CRC and CR
    let length = Int(String(body.dropFirst(8).prefix(4)), radix: 16)
    #expect(length == body.count - 12)
    let crc = String(packet.dropLast().suffix(8))
    #expect(crc == String(format: "%08X", IEMSI.crc32(Array(body.utf8))))
    #expect(packet.contains("{JOHN DOE}{JOHN DOE}{}{}{}{secret}{}{ANSI,24,80,0}{ZMO}"))
}

@Test func iemsiHandshakeAnswersIRQAndAcknowledgesISI() {
    let info = IEMSI.Login(name: "SYSOP", password: "pw", rows: 25, columns: 80, emulation: "ANSI")
    var client = IEMSIClient(login: info)
    #expect(client.feed(Array("Welcome\r\n**EMS".utf8)).isEmpty)
    let ici = client.feed(Array("I_IRQ8E08\r".utf8))
    #expect(String(decoding: ici, as: UTF8.self).hasPrefix("**EMSI_ICI"))
    // A NAK asks again; a second IRQ is not answered twice.
    #expect(String(decoding: client.feed(Array("**EMSI_NAKEEC3\r".utf8)), as: UTF8.self).hasPrefix("**EMSI_ICI"))
    let ack = client.feed(Array("**EMSI_ISI0010{x}{y}{z}{a}{b}{c}12345678\r".utf8))
    #expect(String(decoding: ack, as: UTF8.self) == "**EMSI_ACKA490\r**EMSI_ACKA490\r")
    #expect(client.isFinished)
    #expect(client.feed(Array("**EMSI_IRQ8E08\r".utf8)).isEmpty)
}

@Test func iemsiGivesUpAfterThreeNAKs() {
    var client = IEMSIClient(login: IEMSI.Login(name: "A", password: "B", rows: 25, columns: 80, emulation: "ANSI"))
    _ = client.feed(Array("**EMSI_IRQ8E08\r".utf8))
    _ = client.feed(Array("**EMSI_NAKEEC3\r".utf8))
    _ = client.feed(Array("**EMSI_NAKEEC3\r".utf8))
    #expect(client.feed(Array("**EMSI_NAKEEC3\r".utf8)).isEmpty)
    #expect(client.isFinished)
}

@Test func iemsiEntryToggleRoundTrips() throws {
    var entry = BBSEntry(name: "A", host: "h")
    #expect(!entry.iemsi)
    entry.iemsi = true
    let back = try JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(entry))
    #expect(back.iemsi)
}
