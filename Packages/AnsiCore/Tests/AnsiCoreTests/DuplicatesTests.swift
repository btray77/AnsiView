import Foundation
import Testing
@testable import AnsiCore

struct DuplicatesTests {
    func cellHash(_ bytes: [UInt8], ext: String = "ans") -> String? {
        CellHash.of(AnsiAnalysis(ArtFile(data: Data(bytes), fileExtension: ext)).finalScreen)
    }

    let art = Array("\u{1B}[1;31mHELLO\u{1B}[0m\r\n\u{1B}[44m  WORLD  \u{1B}[0m\r\n".utf8)

    @Test func sauceDoesNotChangeCellHash() {
        let sauce = Sauce(title: "Hello", author: "Someone", group: "Group", date: nil, dataType: 1, fileType: 1,
                          tInfo: [80, 2, 0, 0], flags: 0, fontName: "IBM VGA", comments: [])
        let withSauce = art + [0x1A] + sauce.encoded(fileSize: art.count)
        #expect(cellHash(art) != nil)
        #expect(cellHash(art) == cellHash(withSauce))
        #expect(ByteHash.of(Data(art)) != ByteHash.of(Data(withSauce)))
    }

    @Test func lineEndingsDoNotChangeCellHash() {
        let unix = Array(String(decoding: art, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
        #expect(cellHash(art) == cellHash(unix))
    }

    @Test func trailingBlankRowsIgnored() {
        #expect(cellHash(art) == cellHash(art + Array("\r\n\r\n   \r\n".utf8)))
    }

    @Test func colourChangeChangesHash() {
        let green = Array(String(decoding: art, as: UTF8.self).replacingOccurrences(of: "31m", with: "32m").utf8)
        #expect(cellHash(art) != cellHash(green))
        #expect(cellHash(Array("HELLO".utf8)) != cellHash(Array("HELLp".utf8)))
    }

    @Test func emptyArtHasNoHash() {
        #expect(cellHash([]) == nil)
        #expect(cellHash(Array("   \r\n  ".utf8)) == nil)
        // A coloured background is something to see.
        #expect(cellHash(Array("\u{1B}[44m ".utf8)) != nil)
    }

    @Test func byteHashIsFullSHA256() {
        #expect(ByteHash.of(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func groupsExactBeforeSameArt() {
        // 0 and 1 are exact copies; 2 is the same art with other bytes; 3 is unrelated; 4 is empty.
        let items: [(byteHash: String, cellHash: String?)] = [
            ("b1", "c1"), ("b1", "c1"), ("b2", "c1"), ("b3", "c2"), ("b4", nil), ("b5", nil),
        ]
        let groups = DuplicateFinder.groups(items)
        #expect(groups.count == 2)
        #expect(groups[0].kind == .exact)
        #expect(groups[0].members == [0, 1])
        #expect(groups[1].kind == .sameArt)
        #expect(groups[1].members == [0, 1, 2])
    }

    @Test func exactCopiesOfEmptyArtStillGroup() {
        let groups = DuplicateFinder.groups([("b1", nil), ("b1", nil)])
        #expect(groups.map(\.kind) == [.exact])
    }

    @Test func keepFirstPrefersShortestThenOldest() {
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 100)
        #expect(DuplicateFinder.keeper(paths: ["/a/long/path.ans", "/a/b.ans"], dates: [old, new]) == 1)
        #expect(DuplicateFinder.keeper(paths: ["/a/c.ans", "/a/b.ans"], dates: [new, old]) == 1)
        #expect(DuplicateFinder.keeper(paths: ["/a/b.ans", "/a/c.ans"], dates: [old, old]) == 0)
        #expect(DuplicateFinder.keeper(paths: [], dates: []) == nil)
    }
}
