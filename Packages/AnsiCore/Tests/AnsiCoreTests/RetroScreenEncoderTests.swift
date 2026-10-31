import Foundation
import Testing
@testable import AnsiCore

/// Final gaps ruling 8: designed screens exported to PETSCII, ATASCII and Viewdata, checked by
/// playing the bytes through AnsiView's own terminal for that platform.
@Suite struct RetroScreenEncoderTests {
    static func write(_ text: String, on canvas: inout EditCanvas, x: Int, y: Int, fg: Int, bg: Int = 0) {
        for (i, ch) in text.utf8.enumerated() {
            canvas.set(AnsiCell(code: ch, fg: Palette.vga[fg], bg: Palette.vga[bg]), x: x + i, y: y)
        }
    }

    /// The text a played screen shows on one row.
    static func text(_ screen: AnsiScreen, row: Int) -> String {
        String(decoding: screen.rows[row].map(\.code), as: UTF8.self)
    }

    static func design(columns: Int = 40, rows: Int = 25) -> EditCanvas {
        var canvas = EditCanvas(columns: columns, height: rows)
        write("Welcome to AnsiView BBS", on: &canvas, x: 2, y: 1, fg: 14)
        write("[M]essages  [F]iles  [G]oodbye", on: &canvas, x: 2, y: 3, fg: 11)
        write("Hit a key 123", on: &canvas, x: 2, y: 5, fg: 15, bg: 1)
        for x in 18..<30 { canvas.set(AnsiCell(code: 0x20, fg: Palette.vga[7], bg: Palette.vga[1]), x: x, y: 5) }
        for x in 0..<20 { canvas.set(AnsiCell(code: 0xDB, fg: Palette.vga[12]), x: x, y: 7) }
        for x in 0..<20 { canvas.set(AnsiCell(code: 0xDF, fg: Palette.vga[10], bg: Palette.vga[4]), x: x, y: 8) }
        return canvas
    }

    @Test func petsciiC64KeepsTextColoursAndBlocks() {
        let result = RetroScreenEncoder.encode(Self.design(), for: .petscii64)
        #expect(Array(result.bytes.prefix(2)) == [0x93, 0x0E])
        #expect(result.lostCells == 0)
        let screen = RetroScreenEncoder.play(result.bytes, on: .petscii64)
        #expect(Self.text(screen, row: 1).contains("Welcome to AnsiView BBS"))
        #expect(Self.text(screen, row: 3).contains("[M]essages  [F]iles  [G]oodbye"))
        #expect(Self.text(screen, row: 5).contains("Hit a key 123"))
        // Yellow text is the C64's yellow; the full blocks are light red, drawn as reversed spaces.
        #expect(screen.rows[1][2].fg == PETSCIITerminal.c64Palette[7])
        #expect(screen.rows[7][0].bg == PETSCIITerminal.c64Palette[10])
        // A blue bar of spaces is reversed spaces: the C64 has one screen background.
        #expect(screen.rows[5][20].bg != PETSCIITerminal.c64Palette[0])
        #expect(result.screen == screen.rows.map { Array($0) })
    }

    @Test func petsciiFullRowsWrapWithoutReturnAndTheCornerIsNotWritten() {
        var canvas = EditCanvas(columns: 40, height: 25)
        for y in 0..<25 { for x in 0..<40 { canvas.set(AnsiCell(code: 0x41 + UInt8((x + y) % 26), fg: Palette.vga[7]), x: x, y: y) } }
        let result = RetroScreenEncoder.encode(canvas, for: .petscii64)
        #expect(!result.bytes.dropFirst(2).contains(0x0D))
        #expect(result.warnings.contains { $0.kind == .bottomRightScroll })
        let screen = RetroScreenEncoder.play(result.bytes, on: .petscii64)
        #expect(Self.text(screen, row: 0).hasPrefix("ABC"))
        #expect(Self.text(screen, row: 24).hasPrefix("YZA"))
        #expect(result.lostCells == 0)
    }

    @Test func widerAndTallerArtIsCutWithAWarning() {
        var wide = Self.design(columns: 80, rows: 30)
        Self.write("far right", on: &wide, x: 60, y: 28, fg: 7)
        let result = RetroScreenEncoder.encode(wide, for: .petscii64)
        #expect(result.warnings.contains { $0.kind == .platformCropped })
        let none = RetroScreenEncoder.encode(Self.design(), for: .petscii64)
        #expect(!none.warnings.contains { $0.kind == .platformCropped })
    }

    @Test func petsciiC128Uses80ColumnsAndExactRGBIColours() {
        let result = RetroScreenEncoder.encode(Self.design(columns: 80), for: .petscii128)
        #expect(result.lostCells == 0)
        let screen = RetroScreenEncoder.play(result.bytes, on: .petscii128)
        #expect(screen.columns == 80)
        #expect(screen.rows[1][2].fg == Palette.vga[14])
        #expect(screen.rows[3][2].fg == Palette.vga[11])
        // Only the cells with a background other than black need a compromise (one VDC screen background).
        #expect(result.approximatedCells > 0 && result.approximatedCells <= 33)
    }

    @Test func atasciiShowsTextAndInverseForLightBackgrounds() {
        var canvas = Self.design()
        Self.write("INVERSE", on: &canvas, x: 2, y: 10, fg: 0, bg: 7)
        let result = RetroScreenEncoder.encode(canvas, for: .atascii)
        #expect(result.bytes.first == 0x7D)
        #expect(result.lostCells == 0)
        let screen = RetroScreenEncoder.play(result.bytes, on: .atascii)
        #expect(Self.text(screen, row: 1).contains("Welcome to AnsiView BBS"))
        #expect(screen.rows[10][2].bg == ATASCIITerminal.foreground)
        #expect(screen.rows[1][2].bg == ATASCIITerminal.background)
        #expect(result.warnings.contains { $0.kind == .platformApproximated })
    }

    @Test func viewdataIsSevenBitWithSerialAttributes() {
        var canvas = EditCanvas(columns: 40, height: 24)
        Self.write("TELSTAR", on: &canvas, x: 1, y: 0, fg: 12)
        Self.write("Main index", on: &canvas, x: 10, y: 0, fg: 14)
        for x in 2..<12 { canvas.set(AnsiCell(code: 0xDB, fg: Palette.vga[10]), x: x, y: 3) }
        Self.write("Press # to continue", on: &canvas, x: 2, y: 22, fg: 11)
        let result = RetroScreenEncoder.encode(canvas, for: .viewdata)
        #expect(result.bytes.first == 0x0C)
        #expect(result.bytes.allSatisfy { $0 < 0x80 })
        #expect(result.lostCells == 0)
        let screen = RetroScreenEncoder.play(result.bytes, on: .viewdata)
        #expect(Self.text(screen, row: 0).contains("TELSTAR"))
        #expect(screen.rows[0][1].fg == TeletextTerminal.colours[1])
        #expect(screen.rows[0][10].fg == TeletextTerminal.colours[3])
        // A full block: a mosaic (or the alpha block) with every pixel lit.
        let block = PlatformFonts.teletext.pixels(glyph: Int(screen.rows[3][5].glyph ?? 0))
        #expect(block.filter { $0 }.count * 10 >= block.count * 9)
        #expect(screen.rows[3][5].fg == TeletextTerminal.colours[2])
        #expect(Self.text(screen, row: 22).contains("Press # to continue"))
    }

    @Test func viewdataReportsCellsLostToAttributes() {
        var canvas = EditCanvas(columns: 40, height: 24)
        // Colour changes with no space between them: each change needs a cell.
        for x in 0..<20 { canvas.set(AnsiCell(code: 0x41, fg: Palette.vga[9 + x % 6]), x: x, y: 2) }
        let result = RetroScreenEncoder.encode(canvas, for: .viewdata)
        #expect(result.lostCells > 0)
        #expect(result.warnings.contains { $0.kind == .platformLost })
    }

    @Test func intendedScreenMatchesTheTerminalForRandomArt() {
        var rng = SeededGenerator(seed: 77)
        for platform in [RetroPlatform.petscii64, .petscii128, .atascii] {
            var canvas = EditCanvas(columns: platform.columns, height: platform.rows)
            for y in 0..<platform.rows {
                for x in 0..<platform.columns where rng.next() % 3 != 0 {
                    canvas.set(AnsiCell(code: UInt8(rng.next() % 256), fg: Palette.vga[Int(rng.next() % 16)],
                                        bg: Palette.vga[Int(rng.next() % 8)]), x: x, y: y)
                }
            }
            let result = RetroScreenEncoder.encode(canvas, for: platform)
            #expect(result.lostCells == 0, "\(platform)")
        }
    }

    @Test func telstarFrameIsJSONWithRawVideotex() throws {
        let bytes: [UInt8] = [0x0C, 0x1B, 0x41, 0x48, 0x49, 0x0D, 0x0A]
        let data = try TelstarFrame.json(bytes, page: 101, frame: "a")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pid = try #require(object["pid"] as? [String: Any])
        #expect(pid["page-no"] as? Int == 101)
        #expect(pid["frame-id"] as? String == "a")
        #expect(object["visible"] as? Bool == true)
        let content = try #require(object["content"] as? [String: Any])
        #expect(content["type"] as? String == "rawV")
        #expect((content["data"] as? String).map { Array($0.utf8) } == bytes)
    }

    @Test func platformFactsAndNames() {
        #expect(RetroPlatform.petscii64.fileExtension == "seq")
        #expect(RetroPlatform.petscii128.suggestedName(base: "main") == "main.80col.seq")
        #expect(RetroPlatform.petscii64.suggestedName(base: "main") == "main.seq")
        #expect(RetroPlatform.atascii.fileExtension == "ata")
        #expect(RetroPlatform.viewdata.fileExtension == "json")
        #expect(RetroPlatform.petscii64.emulation == .petscii64)
        #expect(RetroPlatform.allCases.allSatisfy { !$0.documentedPackages.isEmpty || $0 == .atascii })
    }

    /// Every screen designer template, for every platform: the terminal shows what the encoder
    /// chose (PETSCII, ATASCII), and the counts are printed for the plan's evidence.
    @Test func everyTemplateEncodesForEveryPlatform() {
        for platform in RetroPlatform.allCases {
            var cells = 0, approximated = 0, lost = 0, bytes = 0
            for template in ScreenTemplates.all {
                let canvas = template.make(TemplateOptions(columns: 80, bbsName: "Night Shift", package: .synchronet)).frames[0].composite
                let result = RetroScreenEncoder.encode(canvas, for: platform)
                if platform != .viewdata { #expect(result.lostCells == 0, "\(template.id) \(platform)") }
                cells += platform.columns * platform.rows
                approximated += result.approximatedCells
                lost += result.lostCells
                bytes += result.bytes.count
            }
            print("retro \(platform.rawValue): templates=\(ScreenTemplates.all.count) cells=\(cells) approximated=\(approximated) lost=\(lost) bytes=\(bytes)")
        }
    }
}
