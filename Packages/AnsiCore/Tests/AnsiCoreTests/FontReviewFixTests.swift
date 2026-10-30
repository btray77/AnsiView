import Foundation
import Testing
@testable import AnsiCore

/// Fixes from the final review of the fonts branch.
struct FontReviewFixTests {
    /// I1: a FIGlet line stops growing once it is wider than a canvas can be.
    @Test func figletLineWidthIsCapped() throws {
        var lines = ["flf2a$ 1 1 6000 -1 0"]
        let wide = String(repeating: "#", count: 5000)
        for code in 32...126 { lines.append((code == 65 ? wide : "x") + "@@") }
        let font = try FIGletFont.parse(Data(lines.joined(separator: "\n").utf8), name: "Wide")
        let started = Date()
        let rows = font.renderLine(String(repeating: "A", count: 1000), mode: .fullWidth).rows
        #expect(rows[0].count <= EditCanvas.maxColumns + 5000)
        let region = TextArt.render(String(repeating: "A", count: 1000), font: .figlet(font), options: TextArtOptions()).region
        #expect(region.width == EditCanvas.maxColumns)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// M5: AppleDouble entries in Mac made zips are not fonts and not failures.
    @Test func macZipResourceForksAreSkipped() throws {
        let glyph = TDFGlyph(rows: [TDFRow(cells: [TDFCell(code: 0xDB)])])
        let tdf = try TDFFile.write([TDFFont(name: "Mac", type: .block, spacing: 1, glyphs: [65: glyph])])
        let zip = ZipFixture.stored([("FONT.TDF", tdf), ("__MACOSX/._FONT.TDF", Data([0, 5, 22, 7])), ("._OTHER.TDF", Data([1]))])
        let url = FontLibraryTests.tempDirectory().appendingPathComponent("mac.zip")
        try zip.write(to: url)
        let library = FontLibrary(directory: FontLibraryTests.tempDirectory())
        let report = library.importFonts(from: [url])
        #expect(report.fontsAdded == 1)
        #expect(report.failures.isEmpty)
    }

    /// M4: the file cap stops the folder walk; oversized files are refused before reading.
    @Test func importCapsFilesAndSize() throws {
        let source = FontLibraryTests.tempDirectory()
        for index in 0..<5 { try Data("junk".utf8).write(to: source.appendingPathComponent("f\(index).tdf")) }
        let library = FontLibrary(directory: FontLibraryTests.tempDirectory())
        library.maxImportFiles = 3
        let report = library.importFonts(from: [source])
        #expect(report.failures.count == 3)
        library.maxImportFiles = 2000
        library.maxImportFileSize = 2
        let big = FontLibraryTests.tempDirectory().appendingPathComponent("big.flf")
        try Data("flf2a$ 1 1 1 0 0\n".utf8).write(to: big)
        let sized = library.importFonts(from: [big])
        #expect(sized.failures.first?.reason.contains("too large") == true)
    }
}
