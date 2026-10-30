import Foundation
import Testing
@testable import AnsiCore

struct ArtSearchTests {
    func screen(_ text: String) -> AnsiScreen {
        AnsiAnalysis(ArtFile(data: Data(text.utf8), fileExtension: "ans")).finalScreen
    }

    @Test func foldIgnoresCaseAndDiacritics() {
        #expect(ArtSearch.fold("CaF\u{C9} ACiD") == "cafe acid")
        #expect(ArtSearch.fold("") == "")
    }

    @Test func findsWordsInRows() {
        let art = screen("  hello there\r\n\r\nsay HELLO\r\n")
        let found = ArtSearch.matches(in: art, query: "Hello")
        #expect(found == [CellRect(x: 2, y: 0, width: 5, height: 1), CellRect(x: 4, y: 2, width: 5, height: 1)])
    }

    @Test func spacesInQueryMatchRuns() {
        let art = screen("HELLO   WORLD")
        #expect(ArtSearch.matches(in: art, query: "hello world") == [CellRect(x: 0, y: 0, width: 13, height: 1)])
        #expect(ArtSearch.matches(in: art, query: "  hello  ") == [CellRect(x: 0, y: 0, width: 5, height: 1)])
    }

    @Test func blocksAreNotLetters() {
        // Full blocks and shades read as spaces, so "a b" matches across a block but no letter matches one.
        let bytes: [UInt8] = Array("A".utf8) + [0xDB] + Array("B".utf8)
        let art = AnsiAnalysis(ArtFile(data: Data(bytes), fileExtension: "ans")).finalScreen
        #expect(ArtSearch.matches(in: art, query: "ab").isEmpty)
        #expect(ArtSearch.matches(in: art, query: "a b") == [CellRect(x: 0, y: 0, width: 3, height: 1)])
    }

    @Test func overlappingMatchesFoundOnce() {
        #expect(ArtSearch.matches(in: screen("aaaa"), query: "aa").count == 2)
    }

    @Test func emptyQueryFindsNothing() {
        #expect(ArtSearch.matches(in: screen("hello"), query: "   ").isEmpty)
        #expect(ArtSearch.words("  ").isEmpty)
        #expect(ArtSearch.words("Acid  BLADE") == ["acid", "blade"])
    }

    @Test func haystackNeedsEveryWord() {
        let hay = SearchHaystack(name: "BLADE.ANS", title: "Dark Blade", author: "Lord Jazz", group: "ACiD",
                                 comments: "", text: "welcome to the board")
        #expect(hay.matches(words: ArtSearch.words("acid blade")))
        #expect(hay.matches(words: ArtSearch.words("jazz board")))
        #expect(!hay.matches(words: ArtSearch.words("acid ice")))
        #expect(hay.matches(words: []))
    }

    @Test func snippetShowsContext() {
        let hay = SearchHaystack(name: "", title: "", author: "", group: "", comments: "",
                                 text: "line one\nthe quick brown fox jumps\nlast")
        #expect(hay.snippet(for: "brown", radius: 6) == "quick brown fox j")
        #expect(hay.snippet(for: "zebra", radius: 6) == nil)
    }
}
