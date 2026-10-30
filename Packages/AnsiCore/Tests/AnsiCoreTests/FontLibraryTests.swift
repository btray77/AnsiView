import Foundation
import Testing
@testable import AnsiCore

struct FontLibraryTests {
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fontlib-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func tdfData(_ names: [String]) -> Data {
        let glyph = TDFGlyph(rows: [TDFRow(cells: [TDFCell(code: 0xDB)])])
        return try! TDFFile.write(names.map { TDFFont(name: $0, type: .block, spacing: 1, glyphs: [65: glyph]) })
    }

    // MARK: Original fonts

    @Test func originalFontsAreAllTypesAndRoundTrip() throws {
        let tdf = OriginalFonts.tdfFonts
        #expect(tdf.map(\.type) == [.outline, .block, .color])
        let again = try TDFFile.parse(TDFFile.write(tdf)).fonts
        #expect(again == tdf)
        let figlet = try FIGletFont.parse(OriginalFonts.figletData, name: "AV Contour")
        #expect(figlet.glyphs.count >= 95 + 7)
        for font in tdf {
            for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?.,-:'\"()/+=_#*" {
                #expect(font.glyphs[ch.asciiValue!] != nil, "\(font.name) lacks \(ch)")
            }
        }
    }

    @Test func pixelAlphabetHasNoDiagonalsAfterClosing() {
        for (ch, bitmap) in OriginalFonts.alphabet {
            let closed = OriginalFonts.closeDiagonals(bitmap)
            for y in 0..<(closed.count - 1) {
                for x in 0..<(closed[y].count - 1) {
                    let a = closed[y][x], b = closed[y][x + 1], c = closed[y + 1][x], d = closed[y + 1][x + 1]
                    #expect(!((a && d && !b && !c) || (b && c && !a && !d)), "diagonal in \(ch)")
                }
            }
        }
    }

    @Test func outlineFontTracesTheLetter() {
        let outline = OriginalFonts.tdfFonts[0]
        let i = TextArt.render("I", font: .tdf(outline), options: TextArtOptions()).region
        let text = TextArtTests.codes(i)
        // A closed contour: the top row starts with a corner and the bottom row ends with one.
        #expect(text.first?.hasPrefix("┌") == true)
        #expect(text.last?.trimmingCharacters(in: .whitespaces).hasSuffix("┘") == true)
    }

    @Test func colourFontHasShadowAndGradient() {
        let ember = OriginalFonts.tdfFonts[2]
        let attributes = Set(ember.glyphs[65]!.rows.flatMap { $0.cells.map(\.attribute) })
        #expect(attributes.count >= 3)
    }

    // MARK: Library

    @Test func bundledFontsListedFirstRun() throws {
        let library = FontLibrary(directory: Self.tempDirectory())
        let names = library.entries.map(\.name)
        #expect(names.contains("AV Outline") && names.contains("AV Block") && names.contains("AV Ember"))
        #expect(names.contains("AV Contour") && names.contains("standard"))
        #expect(library.entries.count == 4 + 18)
        #expect(library.userEntries.isEmpty)
    }

    @Test func importFilesFoldersAndZips() throws {
        let dir = Self.tempDirectory()
        let source = Self.tempDirectory()
        let library = FontLibrary(directory: dir)
        // A TDF file with two fonts, a FIGlet file and a bad file.
        try Self.tdfData(["One", "Two"]).write(to: source.appendingPathComponent("pair.tdf"))
        try OriginalFonts.figletData.write(to: source.appendingPathComponent("mine.flf"))
        try Data("junk".utf8).write(to: source.appendingPathComponent("bad.tdf"))
        try Data("not a font".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let report = library.importFonts(from: [source])
        #expect(report.filesAdded == 2)
        #expect(report.fontsAdded == 3)
        #expect(report.failures.map(\.file) == ["bad.tdf"])
        #expect(library.userEntries.map(\.name).sorted() == ["One", "Two", "mine"])
        #expect(library.userEntries.first { $0.name == "Two" }?.index == 1)
        // Importing the same file again is a duplicate; a different file with the name gets " 2".
        let again = library.importFonts(from: [source.appendingPathComponent("pair.tdf")])
        #expect(again.filesAdded == 0 && again.duplicates == 1)
        let other = Self.tempDirectory()
        try Self.tdfData(["Three"]).write(to: other.appendingPathComponent("pair.tdf"))
        _ = library.importFonts(from: [other.appendingPathComponent("pair.tdf")])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pair 2.tdf").path))
        // A fresh library on the same folder sees the same fonts.
        #expect(FontLibrary(directory: dir).userEntries.count == 4)
    }

    @Test func importZipPack() throws {
        let dir = Self.tempDirectory()
        let library = FontLibrary(directory: dir)
        let zip = ZipFixture.stored([("fonts/A.TDF", Self.tdfData(["Zipped"])), ("notes.txt", Data("x".utf8))])
        let url = Self.tempDirectory().appendingPathComponent("pack.zip")
        try zip.write(to: url)
        let report = library.importFonts(from: [url])
        #expect(report.fontsAdded == 1)
        #expect(library.userEntries.map(\.name) == ["Zipped"])
    }

    @Test func removeFavouritesRecentAndSampleTextPersist() throws {
        let dir = Self.tempDirectory()
        let source = Self.tempDirectory()
        try Self.tdfData(["One", "Two"]).write(to: source.appendingPathComponent("pair.tdf"))
        let library = FontLibrary(directory: dir)
        _ = library.importFonts(from: [source])
        let two = try #require(library.userEntries.first { $0.name == "Two" })
        library.setFavourite(two.id, true)
        library.noteUsed(two.id)
        library.sampleText = "Hello BBS"
        let reopened = FontLibrary(directory: dir)
        #expect(reopened.favourites == [two.id])
        #expect(reopened.recent == [two.id])
        #expect(reopened.sampleText == "Hello BBS")
        // Removing deletes the file and so both of its fonts.
        #expect(reopened.fontsSharingFile(with: two).count == 2)
        try reopened.remove(two)
        #expect(reopened.userEntries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pair.tdf").path))
        // Bundled fonts cannot be removed.
        #expect(throws: FontLibraryError.bundled) { try reopened.remove(reopened.entries[0]) }
    }

    @Test func searchAndFilters() throws {
        let library = FontLibrary(directory: Self.tempDirectory())
        #expect(library.search("ember").map(\.name) == ["AV Ember"])
        #expect(library.search("SLANT").map(\.name).contains("slant"))
        #expect(library.search("tdf colour").map(\.name) == ["AV Ember"])
        let figlet = library.search("", categories: [.figlet])
        #expect(figlet.count == 19)
        library.setFavourite(library.entries.first { $0.name == "standard" }!.id, true)
        #expect(library.search("", favouritesOnly: true).map(\.name) == ["standard"])
    }

    @Test func loaderRefusesUnknownFiles() {
        #expect(throws: FontLibraryError.unknownFormat) { try FontLoader.fonts(in: Data("hello".utf8), name: "x.txt") }
    }
}

/// Builds a stored (method 0) ZIP for tests.
enum ZipFixture {
    static func stored(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) -> Data { u16(v & 0xFFFF) + u16(v >> 16) }
        for (name, data) in files {
            let offset = out.count
            let nameData = Data(name.utf8)
            out += u32(0x0403_4B50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
            out += u32(data.count) + u32(data.count) + u16(nameData.count) + u16(0) + nameData + data
            central += u32(0x0201_4B50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
            central += u32(data.count) + u32(data.count) + u16(nameData.count) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(0) + u32(offset) + nameData
        }
        let start = out.count
        out += central
        out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(start) + u16(0)
        return out
    }
}
