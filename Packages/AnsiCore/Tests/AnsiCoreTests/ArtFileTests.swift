import Foundation
import Testing
@testable import AnsiCore

private func load(_ raw: [UInt8], _ ext: String? = "ans") -> ArtFile { ArtFile(data: Data(raw), fileExtension: ext) }

@Test func cp437HighBytesAreNotUTF8() {
    #expect(ArtFormat.detect(bytes: [0xDB, 0xDB, 0xB0], fileExtension: "ans", sauce: nil) == .ansi)
}

@Test func validMultibyteIsUTF8() {
    #expect(ArtFormat.detect(bytes: bytes("█▀▄ ok"), fileExtension: "ans", sauce: nil) == .utf8Ansi)
}

@Test func asciiOnlyStaysAnsi() {
    #expect(ArtFormat.detect(bytes: bytes("plain"), fileExtension: "ans", sauce: nil) == .ansi)
}

@Test func utf8BlockMapsToCP437() {
    let cell = AnsiAnalysis(load(bytes("█"))).finalScreen.rows[0][0]
    #expect(cell.code == 0xDB)
    #expect(cell.scalar == nil)
}

@Test func utf8WithoutCP437KeepsScalar() {
    let cell = AnsiAnalysis(load(bytes("€"))).finalScreen.rows[0][0]
    #expect(cell.scalar == "€")
}

@Test func utf8MultibyteTakesOneCell() {
    let row = AnsiAnalysis(load(bytes("█A"))).finalScreen.rows[0]
    #expect(row[1].code == 0x41)
}

@Test func xbinMagicWins() {
    let header = bytes("XBIN") + [0x1A, 80, 0, 25, 0, 16, 0]
    #expect(ArtFormat.detect(bytes: header, fileExtension: "ans", sauce: nil) == .xbin)
}

@Test func extensionsSelectBinaryFormats() {
    #expect(ArtFormat.detect(bytes: [0x41, 0x07], fileExtension: "BIN", sauce: nil) == .bin)
    #expect(ArtFormat.detect(bytes: [0x41, 0x07], fileExtension: "adf", sauce: nil) == .adf)
    #expect(ArtFormat.detect(bytes: [0x41, 0x07], fileExtension: "idf", sauce: nil) == .idf)
}

@Test func sauceBinaryTextWins() {
    let sauce = Sauce.read(makeSauce(dataType: 5, fileType: 40)).sauce
    #expect(ArtFormat.detect(bytes: bytes("AA"), fileExtension: "ans", sauce: sauce) == .bin)
}

@Test func pcboardSniffed() {
    #expect(ArtFormat.detect(bytes: bytes("@X1FHello"), fileExtension: "txt", sauce: nil) == .pcboard)
}

@Test func wildcatSniffed() {
    #expect(ArtFormat.detect(bytes: bytes("@1F@Hello"), fileExtension: "txt", sauce: nil) == .wildcat)
}

@Test func avatarSniffed() {
    #expect(ArtFormat.detect(bytes: [0x16, 0x01, 0x1F] + bytes("Hi"), fileExtension: "txt", sauce: nil) == .avatar)
}

@Test func tenMegabyteStreamLoadsCapped() {
    let big = [UInt8](repeating: 0, count: 0).reserved(10_000_000) + Array(repeating: bytes("A\r\n"), count: 3_400_000).flatMap { $0 }
    #expect(AnsiAnalysis(load(big)).finalScreen.rows.count <= AnsiTerminal.maxRows)
}

@Test func fontComesFromSauce() {
    let file = load(bytes("A") + [0x1A] + makeSauce(font: "IBM EGA"))
    #expect(file.font.height == 14)
}

@Test func ninePixelComesFromSauce() {
    #expect(load(bytes("A") + [0x1A] + makeSauce(flags: 0b0000_0100)).ninePixel)
}

private extension Array {
    func reserved(_ n: Int) -> [Element] { var a = self; a.reserveCapacity(n); return a }
}
