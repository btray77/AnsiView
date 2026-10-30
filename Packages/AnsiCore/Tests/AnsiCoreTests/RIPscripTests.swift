import Foundation
import Testing
@testable import AnsiCore

private func rip(_ text: String) -> RIPTerminal {
    var t = RIPTerminal()
    t.feed(Array(text.utf8))
    return t
}

@Test func megaNumbers() {
    #expect(RIPParser.mega("0A") == 10)
    #expect(RIPParser.mega("ZZ") == 1295)
    #expect(RIPParser.mega("10") == 36)
    #expect(RIPParser.mega("z1") == 35 * 36 + 1)
}

@Test func lineInTheDrawingColour() {
    let t = rip("!|c0F|L00000A00\r\n")
    #expect(t.canvas.pixel(0, 0) == 15 && t.canvas.pixel(10, 0) == 15)
    #expect(t.canvas.pixel(11, 0) == 0)
    #expect(t.canvas.pixel(5, 1) == 0)
}

@Test func rectangleAndBar() {
    let t = rip("!|c0E|R0A0A1414|S010C|B1E1E2828\r\n")
    // MegaNums: 0A is 10, 14 is 40, 1E is 50, 28 is 80.
    #expect(t.canvas.pixel(10, 10) == 14 && t.canvas.pixel(40, 15) == 14)
    #expect(t.canvas.pixel(15, 15) == 0)
    #expect(t.canvas.pixel(60, 60) == 12)
    #expect(t.canvas.pixel(81, 81) == 0)
}

@Test func circleTouchesItsRadius() {
    let t = rip("!|c0F|C2S2S0A\r\n")
    let c = RIPParser.mega("2S")
    #expect(t.canvas.pixel(c + 10, c) == 15)
    #expect(t.canvas.pixel(c, c) == 0)
}

@Test func filledPolygonAndFloodFill() {
    let poly = rip("!|S0109|c0F|p03000028000K14\r\n")
    #expect(poly.canvas.pixel(15, 10) == 9)
    #expect(poly.canvas.pixel(0, 0) == 15)
    let flood = rip("!|c0F|R00000A0A|S0102|F05050F\r\n")
    #expect(flood.canvas.pixel(5, 5) == 2)
    #expect(flood.canvas.pixel(10, 5) == 15)
    #expect(flood.canvas.pixel(15, 5) == 0)
}

@Test func textIsDrawn() {
    let t = rip("!|c0F|@0505Hello\r\n")
    var lit = 0
    for y in 5..<13 { for x in 5..<45 where t.canvas.pixel(x, y) == 15 { lit += 1 } }
    #expect(lit > 20)
}

@Test func paletteChanges() {
    let t = rip("!|a0F04\r\n")
    #expect(t.canvas.palette[15] == RIPCanvas.ega(4))
    let q = rip("!|Q000102030405060708090A0B0C0D0E3F\r\n")
    #expect(q.canvas.palette[1] == RIPCanvas.ega(1))
}

@Test func mouseRegionSendsItsCommand() {
    var t = rip("!|1M000A0A14141000000hello^M\r\n")
    #expect(t.click(x: 15, y: 15) == Array("hello\r".utf8))
    #expect(t.click(x: 50, y: 50) == [])
    t.feed(Array("!|1K\r\n".utf8))
    #expect(t.click(x: 15, y: 15) == [])
}

@Test func buttonDrawsAndClicks() {
    var t = rip("!|1B0000020000020F000F080700000000000000\r\n!|1U0A0A3C1E0000<>OK<>ok^m\r\n")
    #expect(t.click(x: 20, y: 20) == Array("ok\r".utf8))
    #expect(t.canvas.pixel(30, 15) != 0)
}

@Test func ripLinesAreNotShownAsText() {
    let t = rip("Hello\r\n!|c0F|L00000101\r\nWorld")
    let rows = t.screen(scrollOffset: 0).rows
    #expect(String(decoding: rows[0].prefix(5).map(\.code), as: UTF8.self) == "Hello")
    #expect(String(decoding: rows[1].prefix(5).map(\.code), as: UTF8.self) == "World")
}

@Test func ripQueryIsAnswered() {
    var t = rip("\u{1B}[!")
    #expect(String(decoding: t.takeReplies(), as: UTF8.self) == "RIPSCRIP015400")
}

@Test func splitFeedsAndContinuationLines() {
    var t = RIPTerminal()
    for b in Array("!|c0F|L000\\\r\n00A00\r\n".utf8) { t.feed([b]) }
    #expect(t.canvas.pixel(10, 0) == 15)
}

@Test func resetWindowsClearsTheScreen() {
    let t = rip("!|c0F|B00000A0A|*\r\n")
    #expect(t.canvas.pixel(5, 5) == 0)
}

@Test func overlayIsTheEGAScreen() throws {
    let t = rip("!|S010C|B00000A0A\r\n")
    let image = try #require(t.overlay())
    #expect(image.width == 640 && image.height == 350)
    #expect(pixelAt(image, x: 3, y: 3) == RIPCanvas.ega(60))
}

@Test func ripRandomBytesDoNotCrash() {
    var state: UInt64 = 21
    var t = RIPTerminal()
    let alphabet = Array("!|0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz*#@=>\\^`\r\n ".utf8)
    var bytes: [UInt8] = []
    for _ in 0..<200_000 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes.append(alphabet[Int(state >> 33) % alphabet.count])
    }
    t.feed(bytes)
    #expect(t.canvas.width == 640)
}

@Test func invertedViewportEraseDoesNotTrap() {
    // v with x0 > x1 (and beyond the screen), then E erases the viewport.
    let t = rip("!|vHR9P0A0A|E|B00000A0A\r\n")
    #expect(t.canvas.width == 640)
}

@Test(.timeLimit(.minutes(1))) func hugeTextSizesAreCapped() {
    // Font size ZZ (1295) would draw 1295x1295 blocks per pixel without a cap.
    let t = rip("!|YZZ00ZZ00|@0000ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n!|Y00ZZZZ00|@0000ABCDEFGHIJ\r\n")
    #expect(t.canvas.width == 640)
}

@Test func engineFactoryMakesRIP() {
    let e = TerminalEngines.make(.ripscrip, columns: 80, rows: 25, encoding: .cp437, iceColors: false)
    #expect(e is RIPTerminal)
    // The entry's font draws the text layer; the 640x350 picture is shown 4:3.
    #expect(e.font == nil)
    #expect(abs(e.horizontalStretch - 0.729) < 0.001)
}
