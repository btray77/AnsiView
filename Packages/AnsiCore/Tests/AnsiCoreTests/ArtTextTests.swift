import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

struct ArtTextTests {
    func text(_ raw: [UInt8], ext: String = "ans") -> String {
        ArtText.plainText(AnsiAnalysis(ArtFile(data: Data(raw), fileExtension: ext)).finalScreen)
    }

    @Test func textKeepsWordsDropsBlocks() {
        #expect(text([0xDB, 0xDB] + bytes("HELLO") + [0xB0] + bytes(" WORLD")) == "  HELLO  WORLD")
    }

    @Test func boxDrawingBecomesSpace() {
        #expect(text([0xC9, 0xCD, 0xBB] + bytes("\r\n") + [0xBA] + bytes("X") + [0xBA]) == "\n X")
    }

    @Test func trailingSpaceAndLinesTrimmed() {
        #expect(text(bytes("ONE   \r\nTWO\r\n\r\n\r\n   ")) == "ONE\nTWO")
        #expect(text([]) == "")
    }

    @Test func colorsDoNotMatter() {
        #expect(text(bytes("\u{1B}[1;31mRED\u{1B}[0m \u{1B}[44mBLUE")) == "RED BLUE")
    }

    @Test func utf8ScalarsKept() {
        #expect(text(Array("caf\u{E9} \u{2603}".utf8)) == "caf\u{E9} \u{2603}")
    }

    @Test func textIsCapped() {
        let rows = (0..<3000).map { _ in String(repeating: "A", count: 80) }.joined(separator: "\r\n")
        let result = text(bytes(rows))
        #expect(result.count <= ArtText.limit)
        #expect(result.count > ArtText.limit - 100)
    }

    @Test func fieldsFromSauce() {
        let raw = bytes("HI") + [0x1A] + makeSauce(title: "Title", author: "Me", group: "Grp", date: "19960314",
                                                   font: "IBM VGA", comments: ["one", "two"])
        let fields = SpotlightFields(ArtFile(data: Data(raw), fileExtension: "ans"))
        #expect(fields.title == "Title")
        #expect(fields.author == "Me")
        #expect(fields.group == "Grp")
        #expect(fields.date == DateComponents(year: 1996, month: 3, day: 14))
        #expect(fields.comment == "one\ntwo")
        #expect(fields.fontName == "IBM VGA")
        #expect(fields.kind == "ANSI art")
        #expect(fields.text == "HI")
        #expect(fields.pixelSize == CGSize(width: 640, height: 16)) // one row of art
    }

    @Test func fieldsWithoutSauceAreNil() {
        let fields = SpotlightFields(ArtFile(data: Data(bytes("plain")), fileExtension: "ans"))
        #expect(fields.title == nil && fields.author == nil && fields.group == nil)
        #expect(fields.date == nil && fields.comment == nil && fields.fontName == nil)
        #expect(fields.text == "plain")
        let blank = SpotlightFields(ArtFile(data: Data(bytes("x") + makeSauce()), fileExtension: "ans"))
        #expect(blank.title == nil && blank.author == nil && blank.comment == nil && blank.fontName == nil)
    }
}
