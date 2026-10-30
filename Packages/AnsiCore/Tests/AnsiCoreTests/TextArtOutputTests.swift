import Foundation
import Testing
@testable import AnsiCore

struct TextArtOutputTests {
    static func region(_ lines: [String]) -> CanvasRegion {
        CanvasRegion(cells: lines.map { line in
            line.unicodeScalars.map { AnsiCell(code: CP437.code(for: $0) ?? 0x3F, fg: Palette.vga[12], bg: Palette.vga[1]) }
        })
    }

    @Test func plainTextUnicodeAndASCII() {
        let r = Self.region(["┌─┐ █▀  ", "└─┘ ▒░  "])
        #expect(TextArtOutput.plainText(r) == "┌─┐ █▀\n└─┘ ▒░")
        #expect(TextArtOutput.plainText(r, asciiOnly: true) == "+-+ #\"\n+-+ :.")
        // Latin letters with accents become plain letters; anything else is ?.
        #expect(TextArtOutput.plainText(Self.region(["é ∞"]), asciiOnly: true) == "e ?")
    }

    @Test func ansiKeepsColours() {
        let text = TextArtOutput.ansi(Self.region(["AB"]))
        #expect(text.contains("\u{1B}["))
        let back = AnsiAnalysis(ArtFile(data: Data(text.utf8), fileExtension: "ans")).finalScreen
        #expect(back.rows[0][0].code == UInt8(ascii: "A") && back.rows[0][0].fg == Palette.vga[12] && back.rows[0][0].bg == Palette.vga[1])
    }

    @Test func codeComments() {
        let text = " _\n|_|"
        #expect(TextArtOutput.comment(text, style: .slashes) == "//  _\n// |_|")
        #expect(TextArtOutput.comment(text, style: .hash) == "#  _\n# |_|")
        #expect(TextArtOutput.comment(text, style: .dashes) == "--  _\n-- |_|")
        #expect(TextArtOutput.comment(text, style: .semicolon) == ";  _\n; |_|")
        #expect(TextArtOutput.comment(text, style: .block) == "/*\n *  _\n * |_|\n */")
        #expect(TextArtOutput.comment(text, style: .box) == "+-----+\n|  _  |\n| |_| |\n+-----+")
        // A block comment never ends early because the art contains */.
        #expect(!TextArtOutput.comment("*/", style: .block).dropLast(3).contains("*/"))
    }

    @Test func markdownFence() {
        #expect(TextArtOutput.markdown("ab") == "```text\nab\n```")
        #expect(TextArtOutput.markdown("a```b") == "````text\na```b\n````")
    }

    @Test func saveAsANSIIsCP437WithSauce() throws {
        let data = try TextArtOutput.ansFile(Self.region(["█▀"]), title: "Logo")
        #expect(data.contains(0xDB) && data.contains(0xDF))
        #expect(String(decoding: data.suffix(128).prefix(7), as: UTF8.self) == "SAUCE00")
    }
}

struct FontGalleryTests {
    static func entries() -> [FontEntry] {
        FontLibrary(directory: FontLibraryTests.tempDirectory()).entries
    }

    @Test func sortsAndFilters() {
        let all = Self.entries()
        var query = GalleryQuery()
        query.sort = .name
        let byName = FontGallery.arrange(all, query: query, favourites: [], recent: [], sizes: [:])
        #expect(byName.map(\.name) == byName.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        query.categories = [.tdfOutline, .tdfBlock]
        #expect(Set(FontGallery.arrange(all, query: query, favourites: [], recent: [], sizes: [:]).map(\.name)) == ["AV Outline", "AV Block"])
        query.categories = []
        query.search = "small"
        #expect(FontGallery.arrange(all, query: query, favourites: [], recent: [], sizes: [:]).map(\.name) == ["small"])
    }

    @Test func favouritesFirstThenRecent() {
        let all = Self.entries()
        let standard = all.first { $0.name == "standard" }!
        let slant = all.first { $0.name == "slant" }!
        var query = GalleryQuery()
        query.sort = .name
        let arranged = FontGallery.arrange(all, query: query, favourites: [slant.id], recent: [standard.id], sizes: [:])
        #expect(arranged.prefix(2).map(\.name) == ["slant", "standard"])
    }

    @Test func sortByHeightAndWidthAndTallFilter() {
        let all = Self.entries()
        let sizes = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, GallerySize(columns: 100 - $0, rows: $0 % 9 + 1)) })
        var query = GalleryQuery()
        query.sort = .height
        let tall = FontGallery.arrange(all, query: query, favourites: [], recent: [], sizes: sizes)
        #expect(tall.map { sizes[$0.id]!.rows } == tall.map { sizes[$0.id]!.rows }.sorted())
        query.sort = .width
        let wide = FontGallery.arrange(all, query: query, favourites: [], recent: [], sizes: sizes)
        #expect(wide.map { sizes[$0.id]!.columns } == wide.map { sizes[$0.id]!.columns }.sorted())
        query.minimumRows = 6
        #expect(FontGallery.arrange(all, query: query, favourites: [], recent: [], sizes: sizes).allSatisfy { sizes[$0.id]!.rows >= 6 })
    }

    @Test func staleRendersAreDropped() async throws {
        let all = Self.entries()
        let renderer = GalleryRenderer()
        let firstDone = Locked<[String]>([])
        let secondDone = Locked<[String]>([])
        renderer.start(text: "first", entries: all, options: TextArtOptions()) { id, _ in firstDone.mutate { $0.append(id) } }
        renderer.start(text: "second", entries: all, options: TextArtOptions()) { id, _ in secondDone.mutate { $0.append(id) } }
        try await renderer.waitUntilIdle()
        #expect(secondDone.value.count == all.count)
        // The first run was cancelled: it may have finished a few cards, never all of them after
        // the second started, and none of its results arrive with the second generation's ids twice.
        #expect(firstDone.value.count < all.count)
        #expect(Set(secondDone.value).count == all.count)
    }

    @Test func visibleCardsRenderFirst() async throws {
        let all = Self.entries()
        let renderer = GalleryRenderer(concurrency: 1)
        let order = Locked<[String]>([])
        let wanted = [all[10].id, all[15].id]
        renderer.start(text: "Hi", entries: all, options: TextArtOptions(), priority: wanted) { id, _ in
            order.mutate { $0.append(id) }
        }
        try await renderer.waitUntilIdle()
        #expect(Array(order.value.prefix(2)) == wanted)
    }
}

/// A tiny lock box for test callbacks.
final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
