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

/// What VoiceOver reads for the art view (item 34).
struct AccessibilityTextTests {
    func file(_ raw: [UInt8], ext: String = "ans") -> ArtFile { ArtFile(data: Data(raw), fileExtension: ext) }

    @Test func accessibilityValueTrimsRows() {
        let art = file(bytes("  HELLO   \r\n\r\n") + [0xDB, 0xDB] + bytes(" WORLD  \r\n\r\n"))
        #expect(ArtText.accessibilityValue(AnsiAnalysis(art).finalScreen) == "  HELLO\n\n   WORLD")
    }

    @Test func accessibilityLabelFromSauce() {
        let art = file(bytes("HI") + [0x1A] + makeSauce(title: "Title", author: "Me", group: "Grp", date: "19960314"))
        #expect(ArtText.accessibilityLabel(art, fileName: "X.ANS") == "\u{201C}Title\u{201D} by Me, Grp, ANSI art")
        let noGroup = file(bytes("HI") + [0x1A] + makeSauce(title: "", author: "Me", group: "", date: "19960314"))
        #expect(ArtText.accessibilityLabel(noGroup, fileName: "X.ANS") == "By Me, ANSI art")
        let titleOnly = file(bytes("HI") + [0x1A] + makeSauce(title: "Only", author: "", group: "", date: "19960314"))
        #expect(ArtText.accessibilityLabel(titleOnly, fileName: nil) == "\u{201C}Only\u{201D}, ANSI art")
    }

    @Test func accessibilityLabelWithoutSauce() {
        #expect(ArtText.accessibilityLabel(file(bytes("HI")), fileName: "LOGO.ANS") == "LOGO.ANS, ANSI art")
        #expect(ArtText.accessibilityLabel(file(bytes("HI")), fileName: nil) == "ANSI art")
        // A SAUCE record with every name field blank counts as none.
        let blank = file(bytes("HI") + [0x1A] + makeSauce(title: "", author: "", group: "", date: "19960314"))
        #expect(ArtText.accessibilityLabel(blank, fileName: "B.ANS") == "B.ANS, ANSI art")
    }

    @Test func accessibilityEmptyArt() {
        #expect(ArtText.accessibilityValue(AnsiAnalysis(file([])).finalScreen) == "No text")
        #expect(ArtText.accessibilityValue(AnsiAnalysis(file([0xDB, 0xDB, 0xB1])).finalScreen) == "No text")
    }
}
