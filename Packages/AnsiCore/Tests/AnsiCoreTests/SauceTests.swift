import Foundation
import Testing
@testable import AnsiCore

/// A COMNT block (when there are comments) followed by a SAUCE record.
func makeSauce(
    title: String = "", author: String = "", group: String = "", date: String = "",
    dataType: UInt8 = 1, fileType: UInt8 = 1, tInfo: [UInt16] = [80, 25, 0, 0],
    flags: UInt8 = 0, font: String = "", comments: [String] = [], commentCount: UInt8? = nil
) -> [UInt8] {
    func field(_ text: String, _ length: Int, pad: UInt8 = 0x20) -> [UInt8] {
        Array((Array(text.utf8) + [UInt8](repeating: pad, count: length)).prefix(length))
    }
    var out: [UInt8] = []
    if !comments.isEmpty {
        out += bytes("COMNT")
        for comment in comments { out += field(comment, 64) }
    }
    out += bytes("SAUCE00")
    out += field(title, 35) + field(author, 20) + field(group, 20) + field(date, 8)
    out += [0, 0, 0, 0, dataType, fileType]
    for value in tInfo { out += withUnsafeBytes(of: value.littleEndian, Array.init) }
    out += [commentCount ?? UInt8(comments.count), flags]
    out += field(font, 22, pad: 0)
    return out
}

@Test func readsAllFields() {
    let body = bytes("art") + [0x1A]
    let (sauce, length) = Sauce.read(body + makeSauce(
        title: "Test", author: "Me", group: "G", date: "19960314", flags: 0b0000_1101, font: "IBM VGA"))
    let s = try! #require(sauce)
    #expect(s.title == "Test")
    #expect(s.author == "Me")
    #expect(s.group == "G")
    #expect(s.iceColors)
    #expect(s.letterSpacing == .nine)
    #expect(s.aspectRatio == .legacy)
    #expect(s.fontName == "IBM VGA")
    #expect(s.date?.year == 1996)
    #expect(s.date?.month == 3)
    #expect(length == 3)
}

@Test func readsCommentBlock() {
    let body = bytes("art")
    let (sauce, length) = Sauce.read(body + [0x1A] + makeSauce(comments: ["first", "second"]))
    #expect(sauce?.comments == ["first", "second"])
    #expect(length == body.count)
}

@Test func binaryTextWidthComesFromFileType() {
    let (sauce, _) = Sauce.read(makeSauce(dataType: 5, fileType: 80))
    #expect(sauce?.columns == 160)
}

@Test func bogusWidthsFallBack() {
    #expect(Sauce.read(makeSauce(tInfo: [0, 25, 0, 0])).sauce?.columns == nil)
    #expect(Sauce.read(makeSauce(tInfo: [65535, 25, 0, 0])).sauce?.columns == nil)
}

@Test func commentCountLargerThanFileIsIgnored() {
    let body = bytes("art")
    let (sauce, length) = Sauce.read(body + makeSauce(commentCount: 200))
    #expect(sauce?.comments.isEmpty == true)
    #expect(length == body.count)
}

@Test func sauceOnlyFile() {
    let (sauce, length) = Sauce.read(makeSauce(title: "Only"))
    #expect(sauce?.title == "Only")
    #expect(length == 0)
}

@Test func noSauce() {
    let (sauce, length) = Sauce.read(bytes("hi"))
    #expect(sauce == nil)
    #expect(length == 2)
}
