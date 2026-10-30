import Foundation
import Testing
@testable import AnsiCore

struct ArtInfoTests {
    func file(_ raw: [UInt8], ext: String? = "ans") -> ArtFile { ArtFile(data: Data(raw), fileExtension: ext) }

    @Test func sauceRowsInOrder() {
        let raw = bytes("art") + [0x1A] + makeSauce(
            title: "Test", author: "Me", group: "Grp", date: "19960314",
            flags: 0b0000_1101, font: "IBM VGA", comments: ["first line", "second"])
        let info = ArtInfo(file(raw))
        #expect(info.hasSauce)
        #expect(info.rows.map(\.label) == ["Title", "Author", "Group", "Date", "Comments", "Font", "iCE Colors",
                                           "Letter Spacing", "Aspect", "Columns", "Format", "File Size"])
        #expect(info.rows.map(\.value) == ["Test", "Me", "Grp", "1996-03-14", "first line\nsecond", "IBM VGA", "Yes",
                                           "9 pixel", "Legacy 4:3", "80", "ANSI", "\(raw.count) bytes"])
    }

    @Test func noSauceRows() {
        let info = ArtInfo(file(bytes("hi")))
        #expect(!info.hasSauce)
        #expect(ArtInfo.noSauce == "No SAUCE record")
        #expect(info.rows.map(\.label) == ["Columns", "Format", "File Size"])
        #expect(info.rows.map(\.value) == ["80", "ANSI", "2 bytes"])
    }

    @Test func emptyFieldsShowNone() {
        let info = ArtInfo(file(bytes("x") + makeSauce()))
        let values = Dictionary(uniqueKeysWithValues: info.rows.map { ($0.label, $0.value) })
        #expect(values["Title"] == "None")
        #expect(values["Author"] == "None")
        #expect(values["Date"] == "None")
        #expect(values["Font"] == "None")
        #expect(values["Comments"] == nil)
        #expect(values["iCE Colors"] == "No")
        #expect(values["Letter Spacing"] == "Not set")
        #expect(values["Aspect"] == "Not set")
    }

    @Test func byteCountIsRawSize() {
        let raw = bytes("abc") + makeSauce(title: "T")
        #expect(file(raw).byteCount == raw.count)
        #expect(ArtInfo.formatSize(1) == "1 byte")
        #expect(ArtInfo.formatSize(1_234_567) == "1,234,567 bytes")
        #expect(ArtInfo(file([], ext: nil)).rows.last?.value == "0 bytes")
    }

    @Test func formatNames() {
        #expect(ArtFormat.xbin.displayName == "XBin")
        #expect(ArtFormat.utf8Ansi.displayName == "UTF-8 ANSI")
        #expect(ArtFormat.bin.displayName == "BinaryText")
    }
}
