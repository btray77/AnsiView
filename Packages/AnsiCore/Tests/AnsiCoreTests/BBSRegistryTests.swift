import Foundation
import Testing
@testable import AnsiCore

// The owner's "work with ALL BBSes": every registered package, driven by the registry's data.

private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func sent(_ s: String, _ p: BBSPackage) -> AnsiScreen {
    BBSDisplay.screen(BBSDisplay.render(b(s), package: p, samples: SampleValues()), columns: 80, iceColors: false)
}
private func row(_ screen: AnsiScreen, _ y: Int = 0) -> String {
    String(String.UnicodeScalarView(screen.rows[y].map { CP437.unicode[Int($0.code)] }))
        .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
}

private func fixture(blink: Bool) -> EditCanvas {
    var c = EditCanvas(columns: 12, height: 2)
    let cells: [(Int, Int, UInt8, Int, Int, Bool)] = [
        (0, 0, 0x48, 14, 1, false), (1, 0, 0x69, 15, 1, false), (2, 0, 0xDB, 4, 0, false), (3, 0, 0x5B, 7, 2, false),
        (4, 0, 0x7C, 10, 0, false), (5, 0, 0x5C, 3, 0, false), (0, 1, 0x41, 9, 0, false), (1, 1, 0x42, 3, 6, false),
        (2, 1, 0x43, 12, 4, blink),
    ]
    for (x, y, code, fg, bg, bl) in cells { c.set(AnsiCell(code: code, fg: Palette.vga[fg], bg: Palette.vga[bg], blink: bl), x: x, y: y) }
    return c
}

@Test func registryHasEveryDocumentedPackage() {
    let ids = BBSPackage.allCases.map(\.rawValue)
    for id in ["synchronet", "mystic", "wwiv", "enigma", "pcboard", "wildcat", "renegade", "telegard", "iniquity", "oblivion2",
               "impulse", "celerity", "remoteaccess", "proboard", "quickbbs", "spitfire", "searchlight", "daydream", "talisman", "maximus"] {
        #expect(ids.contains(id), "\(id) missing")
    }
    #expect(Set(ids).count == ids.count)
    for package in BBSPackage.allCases {
        #expect(!package.source.isEmpty && !package.displayName.isEmpty, "\(package)")
        let tokens = DisplayCodeCatalog.codes(package).map(\.token)
        #expect(Set(tokens).count == tokens.count, "\(package) has duplicate tokens")
    }
}

@Test(arguments: BBSPackage.allCases.filter { $0.definition.colours != .none })
func everyColourSyntaxRoundTrips(_ package: BBSPackage) {
    let canvas = fixture(blink: package.definition.colours.sendsHighBit)
    let encoded = BBSDisplay.nativeBody(canvas, package: package)
    #expect(!encoded.bytes.contains(0x1B), "\(package)")
    #expect(!encoded.lossy, "\(package)")
    let screen = BBSDisplay.screen(BBSDisplay.render(encoded.bytes, package: package, samples: nil), columns: 12, iceColors: false)
    for y in 0..<2 {
        for x in 0..<6 where canvas[x, y].code != 0x20 {
            let want: AnsiCell = canvas[x, y]
            let got: AnsiCell = screen.rows[y][x]
            let same: Bool = want == got
            #expect(same, "\(package) cell \(x),\(y)")
        }
    }
}

@Test func everyPackageSubstitutesItsUserNameCode() {
    for package in BBSPackage.allCases {
        guard let token = DisplayCodeCatalog.placeholder(.userHandle, package: package) else { continue }
        let text = row(sent("<" + token + ">", package))
        #expect(text.contains("Night Owl") || text.contains("NIGHT OWL"), "\(package) \(token): \(text)")
    }
}

@Test func telegardTildeCodes() {
    #expect(row(sent("~UH on ~SA, node ~CN", .telegard)) == "Night Owl on My BBS, node 1")
}

@Test func iniquityAndOblivionPercentCodes() {
    #expect(row(sent("|14%UN/%BN", .iniquity)) == "Night Owl/My BBS")
    #expect(sent("|14%UN", .iniquity).rows[0][0].fg == Palette.vga[14])
    #expect(row(sent("%UN on node %NN", .oblivion2)) == "Night Owl on node 1")
}

@Test func impulseColoursAndCodes() {
    let screen = sent("%14%B1%UN %BN", .impulse)
    #expect(row(screen) == "Night Owl My BBS")
    #expect(screen.rows[0][0].fg == Palette.vga[14] && screen.rows[0][0].bg == Palette.vga[1])
}

@Test func celerityLettersSwapAndPadding() {
    let screen = sent("|b|S|W@USER:R12@||", .celerity)
    #expect(row(screen) == "   Night Owl|")
    #expect(screen.rows[0][3].fg == Palette.vga[15] && screen.rows[0][3].bg == Palette.vga[1])
    #expect(row(sent("@BBS:C10.@", .celerity)) == "..My BBS..")
}

@Test func remoteAccessProBoardQuickBBSControlCodes() {
    let ra = sent("\u{0B}[1E\u{06}A|\u{06}.........A|", .remoteaccess)
    #expect(row(ra) == "Night Owl|Night Owl |")
    #expect(ra.rows[0][0].fg == Palette.vga[14] && ra.rows[0][0].bg == Palette.vga[1])
    #expect(row(sent("\u{06}##########A|", .proboard)) == "   Night Owl|")
    #expect(row(sent("\u{06}A at \u{0B}I", .quickbbs)) == "Night Owl at 10:42 pm")
}

@Test func spitfireSearchlightDaydreamTalismanMaximus() {
    #expect(row(sent("@NAME@ from @CITYSTATE@", .spitfire)) == "Night Owl from Springfield, IL")
    let sl = sent("\\BL\\IV\\WH\\%N \\\\", .searchlight)
    #expect(row(sl) == "Night Owl \\")
    #expect(sl.rows[0][0].fg == Palette.vga[15] && sl.rows[0][0].bg == Palette.vga[1])
    let dd = sent("|14~#HA@X1FZ\u{03}2Y", .daydream)
    #expect(row(dd) == "Night OwlZY")
    #expect(dd.rows[0][9].bg == Palette.vga[1] && dd.rows[0][10].fg == Palette.vga[14])
    #expect(row(sent("@UNAME######@|", .talisman)) == "Night Owl    |")
    let max = sent("[lightgreen on blue][user] [[x]", .maximus)
    #expect(row(max) == "Night Owl [x]")
    #expect(max.rows[0][0].fg == Palette.vga[10] && max.rows[0][0].bg == Palette.vga[1])
}

@Test func literalStartCharactersAreEscapedOnlyWhenNotACode() {
    var c = EditCanvas(columns: 20, height: 1)
    for (x, code) in ScreenBuilder.codes("[M] [user]").enumerated() { c.set(AnsiCell(code: code), x: x, y: 0) }
    let text = String(decoding: BBSDisplay.nativeBody(c, package: .maximus).bytes, as: UTF8.self)
    #expect(text.hasSuffix("[[M] [user]\r\n"))
}

@Test func newPackagesFileNames() {
    #expect(ExportProfile(package: .spitfire).relativePath(slot: .mainMenu, columns: 80) == "MAIN.CLR")
    #expect(ExportProfile(package: .remoteaccess).relativePath(slot: .matrix, columns: 80) == "LOGO.ANS")
    #expect(ExportProfile(package: .proboard).relativePath(slot: .goodbye, columns: 80) == "GOODBYE.ANS")
    #expect(ExportProfile(package: .iniquity).relativePath(slot: .matrix, columns: 80) == "PRELOGON.ANS")
    #expect(ExportProfile(package: .oblivion2).relativePath(slot: .goodbye, columns: 80) == "GOODBYE.ANS")
    #expect(ExportProfile(package: .impulse).relativePath(slot: .welcome, columns: 80) == "WELCOME.ANS")
    #expect(ExportProfile(package: .talisman).relativePath(slot: .welcome, columns: 80) == "gfiles/welcome.ans")
    #expect(ExportProfile(package: .daydream).relativePath(slot: .mainMenu, columns: 80) == "display/iso/mainmenu.gfx")
    var max = ExportProfile(package: .maximus)
    #expect(max.colourCodes == .native)
    #expect(max.relativePath(slot: .welcome, columns: 80) == "misc/welcome.mec")
    max.colourCodes = .ansi
    #expect(max.relativePath(slot: .welcome, columns: 80) == "misc/welcome.ans")
}
