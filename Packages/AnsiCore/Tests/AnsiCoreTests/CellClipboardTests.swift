import AppKit
import Foundation
import ImageIO
import Testing
@testable import AnsiCore

@Suite struct CellClipboardTests {
    /// A 3 x 2 block: coloured letters, a box character, a truecolor cell, a blinking cell.
    static let sample = CanvasRegion(cells: [
        [AnsiCell(code: 0x41, fg: Palette.vga[14], bg: Palette.vga[1]),
         AnsiCell(code: 0xC4, fg: Palette.vga[10], bg: Palette.vga[0]),
         AnsiCell(code: 0x20, fg: Palette.vga[7], bg: Palette.vga[12])],
        [AnsiCell(code: 0xDB, fg: RGB(r: 10, g: 200, b: 30), bg: Palette.vga[0]),
         AnsiCell(code: 0x62, fg: Palette.vga[7], bg: Palette.vga[4], blink: true),
         AnsiCell()],
    ])

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @Test func allKindWritesEveryRepresentationInOrder() {
        let clip = CellClipboard(region: Self.sample)
        #expect(clip.representations(.all).map(\.type) == [
            CellClipboard.cellsType, CellClipboard.textType, CellClipboard.ansiType,
            CellClipboard.pngType, CellClipboard.tiffType,
        ])
        #expect(clip.representations(.text).map(\.type) == [CellClipboard.textType])
        #expect(clip.representations(.ansi).map(\.type) == [CellClipboard.textType, CellClipboard.ansiType])
        #expect(clip.representations(.image).map(\.type) == [CellClipboard.pngType, CellClipboard.tiffType])
    }

    @Test func textMapsCP437AndTrims() {
        let clip = CellClipboard(region: Self.sample)
        #expect(clip.text == "A─\n█b\n")
    }

    @Test func ansiTextReadsBackAsTheSameCells() throws {
        let clip = CellClipboard(region: Self.sample)
        #expect(clip.ansiText.contains("\u{1B}["))
        #expect(clip.ansiText.contains("38;2;10;200;30"))
        let screen = AnsiParser.parse(Data(clip.ansiText.utf8), fileExtension: "ans")
        for y in 0..<2 {
            for x in 0..<2 {
                let original = Self.sample.cells[y][x]
                let read = screen.rows[y][x]
                #expect(read.fg == original.fg && read.bg == original.bg && read.blink == original.blink)
                #expect(TextConvert.scalar(read) == TextConvert.scalar(original))
            }
        }
        #expect(screen.rows[0][2].bg == Palette.vga[12])
        let ansi = try #require(clip.representations(.ansi).first { $0.type == CellClipboard.ansiType })
        #expect(String(decoding: ansi.data, as: UTF8.self) == clip.ansiText)
    }

    @Test func imageRepresentationSize() throws {
        let clip = CellClipboard(region: Self.sample)
        let pngRep = try #require(clip.representations(.all).first { $0.type == CellClipboard.pngType })
        let png = pngRep.data
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let image = try #require(Self.decode(png))
        #expect(image.width == 3 * 8 * 2 && image.height == 2 * 16 * 2)
        let tiffRep = try #require(clip.representations(.image).first { $0.type == CellClipboard.tiffType })
        let tiffImage = try #require(Self.decode(tiffRep.data))
        #expect(tiffImage.width == 48 && tiffImage.height == 64)
        // Nine pixel cells and another font change the size.
        let nine = CellClipboard(region: Self.sample, font: .vga, ninePixel: true)
        #expect(nine.image()?.width == 3 * 9 * 2)
        let small = CellClipboard(region: Self.sample, font: BitmapFont.named("IBM EGA"))
        #expect(small.image()?.height == 2 * BitmapFont.named("IBM EGA").height * 2)
    }

    @Test func imageShowsTheCellColours() throws {
        let clip = CellClipboard(region: Self.sample)
        let png = try #require(clip.pngData())
        let image = try #require(Self.decode(png))
        // The cell at (2, 0) is a space on bright red: its centre pixel is vga[12].
        let pixel = Self.pixel(image, x: 2 * 16 + 8, y: 16)
        #expect(pixel == Palette.vga[12])
        // The blinking cell draws its text (blink shown).
        let blink = CellClipboard(region: CanvasRegion(cells: [[AnsiCell(code: 0xDB, fg: Palette.vga[15], bg: Palette.vga[0], blink: true)]]))
        let blinkImage = try #require(blink.image())
        #expect(Self.pixel(blinkImage, x: 8, y: 16) == Palette.vga[15])
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGB {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return RGB(r: data[0], g: data[1], b: data[2])
    }

    @Test func hugeRegionLeavesOutThePicture() {
        let row = Array(repeating: AnsiCell(code: 0xDB), count: 1000)
        let huge = CanvasRegion(cells: Array(repeating: row, count: 1500))
        let clip = CellClipboard(region: huge)
        #expect(clip.image() == nil)
        #expect(clip.representations(.all).map(\.type) == [CellClipboard.cellsType, CellClipboard.textType, CellClipboard.ansiType])
        #expect(clip.representations(.image).isEmpty)
        // Too big for scale 2 but fine at scale 1: rendered at scale 1.
        let wide = CanvasRegion(cells: Array(repeating: row, count: 200))
        #expect(CellClipboard(region: wide).image()?.width == 8000)
    }

    @Test func cellBytesRoundTrip() throws {
        let clip = CellClipboard(region: Self.sample)
        let back = try #require(CellClipboard.region(fromCells: clip.cellsData))
        #expect(back == Self.sample)
        #expect(CellClipboard.region(fromCells: Data("nope".utf8)) == nil)
        // The editor's own copy uses the same bytes.
        #expect(CanvasEditor.encode(Self.sample) == clip.cellsData)
    }

    @Test func pasteboardRoundTrip() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("ansiview-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clip = CellClipboard(region: Self.sample)
        board.clearContents()
        let item = NSPasteboardItem()
        for rep in clip.representations(.all) { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
        #expect(board.writeObjects([item]))
        let boardTypes = try #require(board.types)
        let types = boardTypes.map(\.rawValue)
        #expect(CellClipboard.pasteChoice(types: types) == .cells)
        let cells = try #require(board.data(forType: NSPasteboard.PasteboardType(CellClipboard.cellsType)))
        #expect(CellClipboard.region(fromCells: cells) == Self.sample)
        #expect(board.string(forType: .string) == "A─\n█b\n")
        let png = try #require(board.data(forType: .png))
        let image = try #require(Self.decode(png))
        #expect(image.width == 48 && image.height == 64)
        #expect(board.data(forType: .tiff).flatMap(Self.decode)?.width == 48)
        // NSImage (what Preview, Pages and Messages read) finds a picture.
        #expect(NSImage(pasteboard: board)?.size.width ?? 0 > 0)
    }

    @Test func pasteChoicePrefersCellsThenTextOverPictures() {
        typealias C = CellClipboard
        #expect(C.pasteChoice(types: [C.pngType, C.textType, C.cellsType]) == .cells)
        #expect(C.pasteChoice(types: [C.pngType]) == .image(C.pngType))
        #expect(C.pasteChoice(types: [C.tiffType, C.pngType]) == .image(C.pngType))
        #expect(C.pasteChoice(types: [C.jpegType]) == .image(C.jpegType))
        #expect(C.pasteChoice(types: [C.tiffType]) == .image(C.tiffType))
        #expect(C.pasteChoice(types: [C.textType, C.tiffType]) == .text)
        #expect(C.pasteChoice(types: ["public.rtf"]) == nil)
        #expect(C.pasteChoice(types: []) == nil)
    }

    @Test func imageColumns() {
        #expect(CellClipboard.imageColumns(imageWidth: 2000, selectionWidth: nil, canvasColumns: 80) == 80)
        #expect(CellClipboard.imageColumns(imageWidth: 40, selectionWidth: nil, canvasColumns: 80) == 40)
        #expect(CellClipboard.imageColumns(imageWidth: 40, selectionWidth: 12, canvasColumns: 80) == 12)
        #expect(CellClipboard.imageColumns(imageWidth: 0, selectionWidth: nil, canvasColumns: 80) == 1)
    }

    @Test func screenRegionPadsShortRows() {
        let screen = AnsiScreen(columns: 4, rows: [[AnsiCell(code: 0x41)], [AnsiCell(code: 0x42), AnsiCell(code: 0x43)]])
        let region = screen.region(CellRect(x: 0, y: 0, width: 3, height: 3))
        // Clipped to the two rows the screen has; the short first row is padded.
        #expect(region.width == 3 && region.height == 2)
        #expect(region.cells[0][0].code == 0x41 && region.cells[0][2] == AnsiCell())
        #expect(region.cells[1][1].code == 0x43)
        let clipped = screen.region(CellRect(x: 2, y: 1, width: 10, height: 10))
        #expect(clipped.width == 2 && clipped.height == 1)
        #expect(screen.region(CellRect(x: 9, y: 9, width: 1, height: 1)).height == 0)
    }

    @Test func pointToCellMapping() {
        let size = CGSize(width: 800, height: 400)
        let c = CellGrid.cell(at: CGPoint(x: 15, y: 17), in: size, columns: 80, rows: 25)
        #expect(c.x == 1 && c.y == 1)
        let far = CellGrid.cell(at: CGPoint(x: 9000, y: -5), in: size, columns: 80, rows: 25)
        #expect(far.x == 79 && far.y == 0)
        let rect = CellGrid.rect(for: CellRect(x: 1, y: 2, width: 3, height: 4), in: size, columns: 80, rows: 25)
        #expect(rect == CGRect(x: 10, y: 32, width: 30, height: 64))
        #expect(CellGrid.cell(at: .zero, in: .zero, columns: 80, rows: 25) == (0, 0))
    }
}
