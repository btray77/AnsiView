import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

/// Rendered pixels of a screen with its own options at scale 1.
func renderedPixels(_ screen: AnsiScreen) -> (Int, Int, Data) {
    let rendered = AnsiRenderer.render(screen, options: RenderOptions(for: screen, scale: 1))!
    return (rendered.image.width, rendered.image.height, rendered.image.dataProvider!.data! as Data)
}

/// Re-opens saved bytes the way AnsiView opens a file.
func reopened(_ data: Data, ext: String) -> AnsiScreen {
    AnsiAnalysis(ArtFile(data: data, fileExtension: ext)).finalScreen
}

/// Codes a terminal treats as control characters.
let controlCodes: Set<UInt8> = [0x00, 0x07, 0x08, 0x09, 0x0A, 0x0D, 0x1A, 0x1B]

/// Plan 6 ruling 5: all 16 x 16 colour pairs, half blocks, every non control code, optional
/// truecolor, a blank row in the middle, trailing blank rows, 100 columns, iCE on.
func sampleCanvas(trueColor: Bool) -> EditCanvas {
    var canvas = EditCanvas(columns: 100, height: 20)
    canvas.setIceColors(true)
    for i in 0..<256 {
        let fg = i / 16, bg = i % 16
        canvas.set(AnsiCell(code: UInt8(0x41 + i % 26), fg: Palette.vga[fg], bg: Palette.vga[bg]), x: i % 100, y: i / 100)
    }
    for x in 0..<16 {
        canvas.paintHalf(x: x, y: 4, half: .top, color: Palette.vga[x])
        canvas.paintHalf(x: x, y: 4, half: .bottom, color: Palette.vga[15 - x])
    }
    let codes = (0...255).map(UInt8.init).filter { !controlCodes.contains($0) }
    for (i, code) in codes.enumerated() {
        canvas.set(AnsiCell(code: code, fg: Palette.vga[1 + i % 15], bg: Palette.vga[0]), x: i % 100, y: 6 + i / 100)
    }
    // A coloured space at the end of a row and a space with only a foreground colour.
    canvas.set(AnsiCell(code: 0x20, fg: Palette.vga[7], bg: Palette.vga[2]), x: 99, y: 9)
    canvas.set(AnsiCell(code: 0x20, fg: Palette.vga[12], bg: Palette.vga[0]), x: 50, y: 10)
    if trueColor {
        canvas.set(AnsiCell(code: 0x58, fg: RGB(r: 250, g: 1, b: 2), bg: RGB(r: 3, g: 40, b: 99)), x: 0, y: 11)
        canvas.set(AnsiCell(code: 0xDF, fg: RGB(r: 10, g: 20, b: 30), bg: Palette.vga[9]), x: 1, y: 11)
        canvas.set(AnsiCell(code: 0xDC, fg: Palette.vga[14], bg: RGB(r: 200, g: 100, b: 0)), x: 2, y: 11)
    }
    return canvas
}

@Suite struct ArtWriterTests {
    @Test func sauceEncodeReadsBack() {
        let sauce = Sauce(title: "Title é", author: "Author", group: "Group",
                          date: DateComponents(year: 2026, month: 10, day: 30), dataType: 1, fileType: 1,
                          tInfo: [100, 26, 0, 0], flags: 0x05, fontName: "IBM VGA", comments: ["one", "two"])
        let body = Array("hello".utf8)
        let tail = sauce.encoded(fileSize: body.count)
        #expect(tail.suffix(128).count == 128)
        #expect(tail.count == 1 + 5 + 2 * 64 + 128)
        let (read, length) = Sauce.read(body + tail)
        #expect(read == sauce)
        #expect(length == body.count)
        let noComments = Sauce(title: "", author: "", group: "", date: nil, dataType: 1, fileType: 1,
                               tInfo: [80, 0, 0, 0], flags: 0, fontName: "", comments: [])
        #expect(noComments.encoded(fileSize: 0).count == 129)
    }

    @Test func ansRoundTripPixelIdentical() throws {
        for iceOn in [true, false] {
            for trueColor in [false, true] {
                var canvas = sampleCanvas(trueColor: trueColor)
                if !iceOn { canvas.setIceColors(false) }
                let data = try ArtWriter.data(canvas, format: .ansi)
                let back = reopened(data, ext: "ans")
                let expected = canvas.screen(trimmed: true)
                #expect(back.columns == 100)
                #expect(back.rows == expected.rows, "ice \(iceOn) truecolor \(trueColor)")
                let a = renderedPixels(back), b = renderedPixels(expected)
                #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2, "ice \(iceOn) truecolor \(trueColor)")
            }
        }
    }

    @Test func iceOffWritesBlinkCells() throws {
        var canvas = sampleCanvas(trueColor: false)
        canvas.setIceColors(false)
        #expect(canvas.screen(trimmed: true).hasBlink)
        let back = reopened(try ArtWriter.data(canvas, format: .ansi), ext: "ans")
        #expect(back.hasBlink)
        #expect(back.sauce?.iceColors == false)
    }

    @Test func binRoundTripPixelIdentical() throws {
        for iceOn in [true, false] {
            var canvas = sampleCanvas(trueColor: false)
            if !iceOn { canvas.setIceColors(false) }
            let back = reopened(try ArtWriter.data(canvas, format: .bin), ext: "bin")
            let expected = canvas.screen(trimmed: false)
            #expect(back.rows == expected.rows, "ice \(iceOn)")
            let a = renderedPixels(back), b = renderedPixels(expected)
            #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2)
        }
    }

    @Test func xbinRoundTripPixelIdentical() throws {
        for iceOn in [true, false] {
            var canvas = sampleCanvas(trueColor: false)
            if !iceOn { canvas.setIceColors(false) }
            let back = reopened(try ArtWriter.data(canvas, format: .xbin), ext: "xb")
            let expected = canvas.screen(trimmed: false)
            #expect(back.rows == expected.rows, "ice \(iceOn)")
            let a = renderedPixels(back), b = renderedPixels(expected)
            #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2)
        }
    }

    @Test func ansSauceFields() throws {
        var canvas = sampleCanvas(trueColor: false)
        canvas.title = "My Art"
        canvas.author = "Brad"
        canvas.group = "AnsiView"
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 30, hour: 12).date!
        let data = try ArtWriter.data(canvas, format: .ansi, date: date)
        let sauce = try #require(Sauce.read([UInt8](data)).sauce)
        #expect(sauce.title == "My Art" && sauce.author == "Brad" && sauce.group == "AnsiView")
        #expect(sauce.dataType == 1 && sauce.fileType == 1)
        #expect(sauce.tInfo[0] == 100)
        #expect(sauce.tInfo[1] == UInt16(canvas.screen(trimmed: true).rows.count))
        #expect(sauce.iceColors)
        #expect(sauce.fontName == "IBM VGA")
        #expect(sauce.date == DateComponents(year: 2026, month: 10, day: 30))
        let file = ArtFile(data: data, fileExtension: "ans")
        #expect(file.columns == 100 && file.iceColors)
    }

    @Test func binaryAndXBinSauce() throws {
        let canvas = sampleCanvas(trueColor: false)
        let bin = try #require(Sauce.read([UInt8](try ArtWriter.data(canvas, format: .bin))).sauce)
        #expect(bin.dataType == 5 && bin.fileType == 50 && bin.iceColors)
        let xb = try #require(Sauce.read([UInt8](try ArtWriter.data(canvas, format: .xbin))).sauce)
        #expect(xb.dataType == 6 && xb.tInfo[0] == 100 && xb.tInfo[1] == 20)
    }

    @Test func controlCodesBecomeLookalikes() throws {
        var canvas = EditCanvas(columns: 10, height: 1)
        canvas.set(AnsiCell(code: 0x1B), x: 0, y: 0)
        canvas.set(AnsiCell(code: 0x0A), x: 1, y: 0)
        canvas.set(AnsiCell(code: 0x00, fg: Palette.vga[7], bg: Palette.vga[1]), x: 2, y: 0)
        let back = reopened(try ArtWriter.data(canvas, format: .ansi), ext: "ans")
        #expect(back.rows.count == 1)
        #expect(back.rows[0][0].code == 0x3C && back.rows[0][1].code == 0xDB && back.rows[0][2].code == 0x20)
        #expect(back.rows[0][2].bg == Palette.vga[1])
        // Binary formats store them as they are.
        let bin = reopened(try ArtWriter.data(canvas, format: .bin), ext: "bin")
        #expect(bin.rows[0][0].code == 0x1B && bin.rows[0][1].code == 0x0A)
    }

    @Test func binOddWidthPads() throws {
        var canvas = EditCanvas(columns: 81, height: 2)
        canvas.set(AnsiCell(code: 0x41, fg: Palette.vga[14]), x: 80, y: 1)
        let back = reopened(try ArtWriter.data(canvas, format: .bin), ext: "bin")
        #expect(back.columns == 82)
        #expect(back.rows.count == 2)
        #expect(back.rows[1][80] == AnsiCell(code: 0x41, fg: Palette.vga[14]))
        #expect(back.rows[1][81] == AnsiCell())
    }

    @Test func binTooWideThrows() {
        let canvas = EditCanvas(columns: 600, height: 1)
        #expect(throws: ArtWriter.WriteError.self) { try ArtWriter.data(canvas, format: .bin) }
    }

    @Test func binaryNearestVGA() throws {
        var canvas = EditCanvas(columns: 4, height: 1)
        canvas.set(AnsiCell(code: 0x41, fg: RGB(r: 250, g: 1, b: 2), bg: RGB(r: 250, g: 250, b: 250)), x: 0, y: 0)
        for format in [SaveFormat.bin, .xbin] {
            let back = reopened(try ArtWriter.data(canvas, format: format), ext: format.fileExtension)
            #expect(back.rows[0][0].fg == Palette.vga[4])
            // iCE off: a background is limited to the dark colours.
            #expect(back.rows[0][0].bg == Palette.vga[7])
            #expect(!back.rows[0][0].blink)
        }
    }

    @Test func trailingBlankRowsNotWritten() throws {
        var canvas = EditCanvas()
        canvas.set(AnsiCell(code: 0x41), x: 0, y: 1)
        let data = try ArtWriter.data(canvas, format: .ansi)
        let body = ArtWriter.ansiBody(canvas)
        #expect(body.filter { $0 == 0x0A }.count == 2)
        #expect(reopened(data, ext: "ans").rows.count == 2)
        #expect(data.count == body.count + 129)
    }

    @Test func saveFormatExtensions() {
        #expect(SaveFormat.allCases.map(\.fileExtension) == ["ans", "bin", "xb"])
    }
}

@Suite struct ArtWriterEncodingTests {
    /// CP437 box characters can form valid UTF-8 ("─┐" is C4 BF); the saved file must still read as CP437.
    @Test func boxDrawingStaysCP437() throws {
        var canvas = EditCanvas()
        canvas.set(AnsiCell(code: 0xC4), x: 0, y: 0)
        canvas.set(AnsiCell(code: 0xBF), x: 1, y: 0)
        let data = try ArtWriter.data(canvas, format: .ansi)
        let file = ArtFile(data: data, fileExtension: "ans")
        #expect(file.format == .ansi)
        let back = reopened(data, ext: "ans")
        #expect(back.rows[0][0].code == 0xC4 && back.rows[0][1].code == 0xBF)
    }

    /// UTF-8 art without a SAUCE font name is still detected as UTF-8.
    @Test func utf8ArtStillDetected() {
        #expect(ArtFile(data: Data("\u{1B}[31m─┐ héllo".utf8), fileExtension: "ans").format == .utf8Ansi)
    }
}
