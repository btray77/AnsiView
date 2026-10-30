import Foundation
import Testing
@testable import AnsiCore

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
private func shown(_ bytes: [UInt8], ice: Bool = false) -> AnsiScreen {
    AnsiAnalysis(ArtFile(data: Data(bytes), fileExtension: ice ? "ice" : "ans")).finalScreen
}
private func rowText(_ screen: AnsiScreen, _ y: Int) -> String {
    String(String.UnicodeScalarView(screen.rows[y].map { CP437.unicode[Int($0.code)] })).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
}

/// A small canvas using every kind of attribute the codes can carry.
private func fixture(ice: Bool, blink: Bool = true) -> EditCanvas {
    var c = EditCanvas(columns: 12, height: 3)
    let cells: [(Int, Int, UInt8, Int, Int, Bool)] = [
        (0, 0, 0x48, 14, 1, false), (1, 0, 0x69, 15, 1, false), (2, 0, 0xDB, 4, 0, false), (3, 0, 0x20, 7, 2, false),
        (0, 1, 0x41, 9, 0, false), (1, 1, 0x42, 3, 6, false), (2, 1, 0x43, 12, 4, blink),
        (0, 2, 0xC9, 10, 0, false), (5, 2, 0x5A, 0, 7, false),
    ]
    if ice { c.setIceColors(true) }
    for (x, y, code, fg, bg, blink) in cells {
        var cell = AnsiCell(code: code, fg: Palette.vga[fg], bg: Palette.vga[bg], blink: blink)
        if ice && blink { cell.blink = false; cell.bg = Palette.vga[bg + 8] }
        c.set(cell, x: x, y: y)
    }
    return c
}

private func sameCells(_ a: EditCanvas, _ screen: AnsiScreen) -> Bool {
    for y in 0..<a.height {
        for x in 0..<a.columns {
            let want = a[x, y], got = y < screen.rows.count && x < screen.rows[y].count ? screen.rows[y][x] : AnsiCell()
            if want.code == 0x20 && want.bg == Palette.vga[0] && got.code == 0x20 && got.bg == Palette.vga[0] { continue }
            if want.code != got.code || want.fg != got.fg || want.bg != got.bg || want.blink != got.blink { return false }
        }
    }
    return true
}

// MARK: Colour round trips: canvas -> native codes -> what the BBS sends -> the same cells

@Test(arguments: [BBSPackage.synchronet, .mystic, .enigma, .pcboard, .wildcat, .renegade, .wwiv])
func nativeColourCodesRoundTrip(_ package: BBSPackage) {
    // Renegade and WWIV pipes have no documented blink code.
    let canvas = fixture(ice: false, blink: package != .renegade && package != .wwiv)
    let encoded = BBSDisplay.nativeBody(canvas, package: package)
    #expect(!encoded.bytes.contains(0x1B), "native codes carry no escape sequences")
    let sent = BBSDisplay.render(encoded.bytes, package: package, samples: nil)
    #expect(sameCells(canvas, shown(sent)), "\(package)")
}

@Test(arguments: [BBSPackage.synchronet, .mystic, .enigma, .pcboard, .wildcat])
func iceBackgroundsRoundTrip(_ package: BBSPackage) {
    let canvas = fixture(ice: true)
    let encoded = BBSDisplay.nativeBody(canvas, package: package)
    #expect(!encoded.lossy)
    let sent = BBSDisplay.render(encoded.bytes, package: package, samples: nil)
    #expect(sameCells(canvas, shown(sent, ice: true)), "\(package)")
}

@Test func renegadeCannotSendBlinkSoItIsMarkedLossy() {
    #expect(BBSDisplay.nativeBody(fixture(ice: false), package: .renegade).lossy)
    #expect(!BBSDisplay.nativeBody(fixture(ice: false), package: .mystic).lossy)
}

// MARK: Exported bytes against the documented formats

@Test func synchronetCtrlAFormat() {
    var c = EditCanvas(columns: 4, height: 1)
    c.set(AnsiCell(code: 0x41, fg: Palette.vga[14], bg: Palette.vga[1]), x: 0, y: 0)
    let bytes = BBSDisplay.nativeBody(c, package: .synchronet).bytes
    // Normal, yellow letter (Y), blue background (4), high intensity, then the character.
    #expect(bytes == [0x01, 0x4E, 0x01, 0x59, 0x01, 0x34, 0x01, 0x48, 0x41, 0x0D, 0x0A])
}

@Test func mysticPipeFormat() {
    var c = EditCanvas(columns: 4, height: 1)
    c.set(AnsiCell(code: 0x41, fg: Palette.vga[14], bg: Palette.vga[1]), x: 0, y: 0)
    c.set(AnsiCell(code: 0x42, fg: Palette.vga[12], bg: Palette.vga[1], blink: true), x: 1, y: 0)
    #expect(text(BBSDisplay.nativeBody(c, package: .mystic).bytes) == "|17|14A|25|12B\r\n")
}

@Test func pcboardAndWildcatFormats() {
    var c = EditCanvas(columns: 4, height: 1)
    c.set(AnsiCell(code: 0x41, fg: Palette.vga[15], bg: Palette.vga[1]), x: 0, y: 0)
    c.set(AnsiCell(code: 0x42, fg: Palette.vga[15], bg: Palette.vga[1], blink: true), x: 1, y: 0)
    #expect(text(BBSDisplay.nativeBody(c, package: .pcboard).bytes) == "@X1FA@X9FB\r\n")
    #expect(text(BBSDisplay.nativeBody(c, package: .wildcat).bytes) == "@1F@A@9F@B\r\n")
}

@Test func pcboardNeverWritesTheSaveAndRestoreCodes() {
    var c = EditCanvas(columns: 2, height: 1)
    c.set(AnsiCell(code: 0x20, fg: Palette.vga[0], bg: Palette.vga[0]), x: 0, y: 0)
    c.set(AnsiCell(code: 0x41, fg: Palette.vga[7], bg: Palette.vga[0]), x: 1, y: 0)
    let s = text(BBSDisplay.nativeBody(c, package: .pcboard).bytes)
    #expect(!s.contains("@X00") && !s.contains("@XFF"))
}

// MARK: What the BBS sends: codes substituted with sample values

@Test func mysticSubstitutesMCIAndPadding() {
    var samples = SampleValues()
    samples[.userHandle] = "Night Owl"
    let sent = BBSDisplay.render(b("|14Hi |UH! [|$R10|UH] |CS calls"), package: .mystic, samples: samples)
    #expect(rowText(shown(sent), 0) == "Hi Night Owl! [ Night Owl] 42 calls")
    #expect(shown(sent).rows[0][0].fg == Palette.vga[14])
}

@Test func mysticClearScreenAndNewline() {
    let screen = shown(BBSDisplay.render(b("junk|CLTop|CRNext"), package: .mystic, samples: SampleValues()))
    #expect(rowText(screen, 0) == "Top")
    #expect(rowText(screen, 1) == "Next")
}

@Test func synchronetAtCodesWithModifiers() {
    let samples = SampleValues()
    let sent = BBSDisplay.render(b("@ALIAS@|@NODE|Z3@|@ALIAS|R12@|@ALIAS|L######@|@BBS-U@"), package: .synchronet, samples: samples)
    #expect(rowText(shown(sent), 0) == "Night Owl|001|   Night Owl|Night Owl      |MY BBS")
}

@Test func synchronetCtrlAActionsAndUnknownCodes() {
    let sent = BBSDisplay.render([0x01, 0x4C] + b("A") + [0x01, 0x5D] + b("@NOTACODE@"), package: .synchronet, samples: SampleValues())
    let screen = shown(sent)
    #expect(rowText(screen, 0) == "A")
    #expect(rowText(screen, 1) == "@NOTACODE@")
}

@Test func pcboardMacrosAndPadding() {
    let sent = BBSDisplay.render(b("@X0E@USER@ @FIRST:8R@ node @NODE@"), package: .pcboard, samples: SampleValues())
    let screen = shown(sent)
    #expect(rowText(screen, 0) == "NIGHT OWL    Night node 1")
    #expect(screen.rows[0][0].fg == Palette.vga[14])
}

@Test func wwivHeartsPipesAndMacros() {
    // Heart 4 is bright white on blue in WWIV's default new user colours.
    let sent = BBSDisplay.render([0x03, 0x34] + b("X|@N|07|@Y"), package: .wwiv, samples: SampleValues())
    let screen = shown(sent)
    #expect(rowText(screen, 0) == "XNight OwlMy BBS")
    #expect(screen.rows[0][0].fg == Palette.vga[15] && screen.rows[0][0].bg == Palette.vga[1])
    #expect(screen.rows[0][10].fg == Palette.vga[7])
}

@Test func enigmaMCIAndViews() {
    let sent = BBSDisplay.render(b("|11%BN %UN %TL1"), package: .enigma, samples: SampleValues())
    #expect(rowText(shown(sent), 0) == "My BBS Night Owl [TL1]")
}

@Test func renegadeMCIIsCaseBlind() {
    let sent = BBSDisplay.render(b("|12%bn/%UN"), package: .renegade, samples: SampleValues())
    #expect(rowText(shown(sent), 0) == "My BBS/Night Owl")
}

@Test func colourOnlyLeavesTextCodesForTheEditor() {
    let sent = BBSDisplay.render(b("|14|UH"), package: .mystic, samples: nil)
    let screen = shown(sent)
    #expect(rowText(screen, 0) == "|UH")
    #expect(screen.rows[0][0].fg == Palette.vga[14])
}

@Test func renderStopsAtEndOfFile() {
    let sent = BBSDisplay.render(b("ok") + [0x1A] + b("SAUCE00"), package: .mystic, samples: SampleValues())
    #expect(text(sent).hasSuffix("ok"))
}

// MARK: Codes the chosen BBS does not read

@Test func foreignCodesAreFound() {
    #expect(BBSDisplay.foreignCodes(in: b("Hi |UH, node @NODE@"), package: .mystic) == ["@NODE@"])
    #expect(BBSDisplay.foreignCodes(in: b("Hi |UH, node @NODE@"), package: .synchronet) == ["|UH"])
    #expect(BBSDisplay.foreignCodes(in: b("%BN |07 @X1F"), package: .renegade) == ["@X1F"])
    #expect(BBSDisplay.foreignCodes(in: b("100% sure, a|b"), package: .synchronet).isEmpty)
    #expect(BBSDisplay.foreignCodes(in: [0x01, 0x48] + b("x"), package: .mystic) == ["^AH"])
    #expect(BBSDisplay.foreignCodes(in: b("|28"), package: .renegade) == ["|28"])
}

// MARK: Catalogue

@Test func catalogueSearchAndPlaceholders() {
    #expect(DisplayCodeCatalog.placeholder(.userHandle, package: .mystic) == "|UH")
    #expect(DisplayCodeCatalog.placeholder(.realName, package: .mystic) == "|UN")
    #expect(DisplayCodeCatalog.placeholder(.bbsName, package: .synchronet) == "@BBS@")
    #expect(DisplayCodeCatalog.placeholder(.bbsName, package: .pcboard) == "@BOARDNAME@")
    #expect(DisplayCodeCatalog.placeholder(.bbsName, package: .wildcat) == nil)
    #expect(DisplayCodeCatalog.placeholder(.sysop, package: .pcboard) == nil)
    let found = DisplayCodeCatalog.search("time left", package: .mystic)
    #expect(found.first?.codes.map(\.token) == ["|TL"])
    #expect(DisplayCodeCatalog.search("", package: .mystic).map(\.group) == [.user, .system, .time, .screen, .colour])
    for package in BBSPackage.allCases {
        let tokens = DisplayCodeCatalog.codes(package).map(\.token)
        #expect(Set(tokens).count == tokens.count, "\(package) has duplicate tokens")
    }
}
