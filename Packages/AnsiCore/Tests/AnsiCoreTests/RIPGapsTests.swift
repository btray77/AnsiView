import Foundation
import Testing
@testable import AnsiCore

/// Files in memory, looked up without regard to case (as the folder provider does).
final class MemoryRIPFiles: RIPFileProvider {
    var files: [String: [UInt8]] = [:]
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    init(_ files: [String: [UInt8]] = [:]) {
        for (k, v) in files { self.files[k.lowercased()] = v }
    }
    func data(named name: String) -> [UInt8]? { files[name.lowercased()] }
    func info(named name: String) -> (size: Int, date: Date)? { files[name.lowercased()].map { ($0.count, date) } }
}

private let specIcon: [UInt8] = [0x05, 0x00, 0x01, 0x00, 0x0C, 0x14, 0x24, 0x44, 0x20, 0x40, 0x98, 0xC4, 0x00]

private func rip(_ text: String, files: RIPFileProvider? = nil) -> RIPTerminal {
    var t = RIPTerminal()
    t.files = files
    t.feed(Array(text.utf8))
    return t
}

// MARK: Icons

@Test func iconDecodesTheSpecExample() throws {
    let icon = try #require(RIPIcon.decode(specIcon))
    #expect(icon.width == 6 && icon.height == 2)
    // The spec's picture shows 03 for the fourth pixel of the second line, but its own bytes
    // (plane 1 98h, plane 0 C4h) encode 02; the bytes are what icon files contain.
    #expect(icon.pixels == [0, 1, 2, 4, 8, 15, 3, 5, 8, 2, 2, 1])
    #expect(icon.encode() == specIcon)
}

@Test func truncatedOrHugeIconsAreRefused() {
    #expect(RIPIcon.decode(Array(specIcon.prefix(8))) == nil)
    #expect(RIPIcon.decode([0xFF, 0xFF, 0xFF, 0xFF]) == nil)
    #expect(RIPIcon.decode([]) == nil)
}

@Test func fileNamesFromTheBBSStayInTheFolder() {
    #expect(RIPFileName.sanitize(Array("../../etc/passwd".utf8)) == "passwd")
    #expect(RIPFileName.sanitize(Array("C:\\RIP\\ICONS\\X.ICN".utf8)) == "X.ICN")
    #expect(RIPFileName.sanitize(Array(".hidden".utf8)) == nil)
    #expect(RIPFileName.sanitize(Array("..".utf8)) == nil)
    #expect(RIPFileName.sanitize(Array("".utf8)) == nil)
    #expect(RIPFileName.icon(Array("button".utf8)) == "button.ICN")
    #expect(RIPFileName.icon(Array("button.hic".utf8)) == "button.hic")
}

@Test func loadIconDrawsItFromTheFolder() {
    let t = rip("!|1I0A0A00010button\r\n", files: MemoryRIPFiles(["BUTTON.ICN": specIcon]))
    #expect((0..<6).map { t.canvas.pixel(10 + $0, 10) } == [0, 1, 2, 4, 8, 15])
    #expect((0..<6).map { t.canvas.pixel(10 + $0, 11) } == [3, 5, 8, 2, 2, 1])
}

@Test func loadIconXorModeAndClipboard() {
    var t = rip("!|c0F|B0000ZZ0Z\r\n", files: MemoryRIPFiles(["A.ICN": specIcon]))
    t.feed(Array("!|S010F|B00000505|1I000001110a\r\n".utf8))
    #expect(t.canvas.pixel(5, 0) == 0)       // 15 xor 15
    #expect(t.canvas.pixel(1, 0) == 14)      // 15 xor 1
    #expect(t.clipboardSize?.width == 6)
}

@Test func missingIconShowsABox() {
    let t = rip("!|1I0A0A00010nothere\r\n", files: MemoryRIPFiles())
    #expect((0..<350).contains { y in (0..<640).contains { t.canvas.pixel($0, y) != 0 } })
}

@Test func writtenIconsLiveForTheSessionOnly() {
    let files = MemoryRIPFiles()
    var t = rip("!|c0C|X0101|1C00000202|1W0saved\r\n", files: files)
    t.feed(Array("!|1I1414000 10saved\r\n".replacingOccurrences(of: " ", with: "").utf8))
    #expect(t.canvas.pixel(41, 41) == 12)
    #expect(files.files.isEmpty)
}

// MARK: Scenes and queries

@Test func fileQueryModes() {
    let files = MemoryRIPFiles(["BUTTON.ICN": specIcon])
    files.date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                year: 1993, month: 1, day: 2, hour: 3, minute: 4, second: 30).date!
    func reply(_ query: String) -> String {
        var t = rip(query, files: files)
        return String(decoding: t.takeReplies(), as: UTF8.self)
    }
    #expect(reply("!|1F000000button.icn\r\n") == "1")
    #expect(reply("!|1F000000missing.icn\r\n") == "0")
    #expect(reply("!|1F010000button.icn\r\n") == "1\r")
    #expect(reply("!|1F020000button.icn\r\n") == "1.13\r")
    #expect(reply("!|1F020000missing.icn\r\n") == "0\r")
    #expect(reply("!|1F030000button.icn\r\n") == "1.13.01/02/93.03:04:30\r")
    #expect(reply("!|1F040000button.icn\r\n") == "1.BUTTON.ICN.13.01/02/93.03:04:30\r")
}

@Test func readScenePlaysALocalFile() {
    let files = MemoryRIPFiles(["SCENE.RIP": Array("!|c0F|X0505\r\nhello".utf8)])
    let t = rip("!|1R00000000scene.rip\r\n!|X0606\r\n", files: files)
    #expect(t.canvas.pixel(5, 5) == 15)
    #expect(t.canvas.pixel(6, 6) == 15)
    #expect(TextConvert.utf8Text(t.screen(scrollOffset: 0)).contains("hello"))
}

@Test func readSceneDoesNotRecurse() {
    let files = MemoryRIPFiles(["LOOP.RIP": Array("!|c0F|X0505\r\n!|1R00000000loop.rip\r\n".utf8)])
    let t = rip("!|1R00000000loop.rip\r\n", files: files)
    #expect(t.canvas.pixel(5, 5) == 15)
}

@Test func copyRegionMovesLines() {
    let t = rip("!|c0F|X0800|1G08000G000005\r\n")
    #expect(t.canvas.pixel(8, 5) == 15)
    #expect(t.canvas.pixel(8, 0) == 15)
}

@Test func queryAnswersAtOnce() {
    var t = rip("!|1\u{1B}0000hello^m\r\n")
    #expect(t.takeReplies() == Array("hello\r".utf8))
}

@Test func blockTransferIsReported() throws {
    var t = rip("!|9\u{1B}00010000ICONFILE.ICN<>\r\n")
    let taken = t.takeBlockTransfer()
    let request = try #require(taken)
    #expect(request.upload == false && request.protocolCode == 0 && request.fileType == 1)
    #expect(request.fileName == "ICONFILE.ICN")
    #expect(t.takeBlockTransfer() == nil)
    var z = rip("!|9\u{1B}07040000<>\r\n")
    #expect(z.takeBlockTransfer()?.fileName == nil)
}

// MARK: Stroke fonts

private func litBox(_ t: RIPTerminal) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
    var box: (Int, Int, Int, Int)?
    for y in 0..<350 { for x in 0..<640 where t.canvas.pixel(x, y) != 0 {
        box = box.map { (min($0.0, x), min($0.1, y), max($0.2, x), max($0.3, y)) } ?? (x, y, x, y)
    } }
    return box
}

@Test func strokeFontsUseTheMetricTables() throws {
    let m = RIPStrokeFont.metrics(font: 1, size: 4)
    #expect(m.top == 10 && m.base == 31 && m.drop == 38)
    let t = rip("!|c0F|Y010004|@0A0AH\r\n")
    let box = try #require(litBox(t))
    // The H stands from the font's top line to its baseline.
    #expect(abs(box.y0 - (10 + m.top)) <= 2)
    #expect(abs(box.y1 - (10 + m.base)) <= 3)
}

@Test func everyPrintableCharacterHasStrokes() {
    for byte in UInt8(0x21)...UInt8(0x7E) {
        #expect(!RIPStrokeFont.strokes(for: byte).isEmpty, "\(Character(Unicode.Scalar(byte)))")
        #expect(RIPStrokeFont.strokes(for: byte).allSatisfy { $0.allSatisfy { (0...6).contains($0.x) && (0...11).contains($0.y) } })
    }
}

@Test func verticalStrokeTextRunsUpwards() throws {
    let t = rip("!|c0F|Y030104|@1E8QHHHH\r\n")
    let box = try #require(litBox(t))
    #expect(box.y1 - box.y0 > box.x1 - box.x0)
}

@Test func strokeTextWidthMatchesDrawing() {
    var canvas = RIPCanvas()
    canvas.font = 3; canvas.size = 2
    let width = canvas.textWidth(Array("HELLO".utf8))
    canvas.text(Array("HELLO".utf8), x: 0, y: 0)
    #expect(canvas.position.x == width)
}

// MARK: Buttons

// Style: plain (256), mouse (1024), radio group (16384) = 17664 = "0DMO"; group 1.
private let radioStyle = "!|1B0000020DMO000F000F080701000E07000000\r\n"
// Style: plain mouse (1280 = "00ZK"), check box group (flags2 1), group 2.
private let checkStyle = "!|1B00000200ZK000F000F080702010E07000000\r\n"

@Test func radioButtonsSelectOneAtATime() {
    var t = rip(radioStyle + "!|1U0A0A0U140000<>One<>A|1U140A1E140000<>Two<>B\r\n")
    #expect(t.click(x: 15, y: 15) == Array("A".utf8))
    #expect(t.selectedButtons == [0])
    #expect(t.click(x: 45, y: 15) == Array("B".utf8))
    #expect(t.selectedButtons == [1])
}

@Test func checkBoxesToggle() {
    var t = rip(checkStyle + "!|1U0A0A0U140000<>One<>A\r\n")
    _ = t.click(x: 15, y: 15)
    #expect(t.selectedButtons == [0])
    _ = t.click(x: 15, y: 15)
    #expect(t.selectedButtons == [])
}

@Test func preselectedButtonDrawsSelected() {
    let t = rip(radioStyle + "!|1U0A0A0U140010<>One<>A\r\n")
    #expect(t.selectedButtons == [0])
}

@Test func buttonHotkeySendsItsCommand() {
    var t = rip("!|1B00000200ZK000F000F080700000E07000000\r\n!|1U0A0A0U142G00<>Exit<>X^m\r\n")
    #expect(t.hotkey(UInt8(ascii: "X")) == Array("X\r".utf8))
    #expect(t.hotkey(UInt8(ascii: "Q")) == nil)
}

@Test func beveledButtonGrowsByTheBevel() {
    // Plain (256) + bevel (512) + mouse (1024) = 1792 = "01DS"; bevel 3; bright 15, dark 8.
    let t = rip("!|1B000002" + "01DS" + "03" + "0F000F0807" + "0000" + "0E07000000\r\n!|1U1414281E0000<>Go<>G\r\n")
    #expect(t.canvas.pixel(40 - 3, 40) == 15)
    #expect(t.canvas.pixel(80 + 3, 50) == 8)
}

// MARK: Budget

@Test func drawingBudgetDefersWork() {
    var t = RIPTerminal()
    t.drawingBudget = 1000
    t.feed(Array("!|S010C|B0000HS9Q\r\n!|c0F|X0101\r\nZ".utf8))
    #expect(t.hasPendingWork)
    #expect(t.canvas.pixel(1, 1) == 12)
    #expect(!TextConvert.utf8Text(t.screen(scrollOffset: 0)).contains("Z"))
    var rounds = 0
    while t.hasPendingWork, rounds < 100 { t.feed([]); rounds += 1 }
    #expect(!t.hasPendingWork)
    #expect(t.canvas.pixel(1, 1) == 15)
    #expect(TextConvert.utf8Text(t.screen(scrollOffset: 0)).contains("Z"))
}

@Test func randomStreamsDrainUnderTheBudget() {
    var seed: UInt64 = 0x5EED
    func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
    let alphabet = Array("!|0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ<>\r\n1RIUFCGBYSs@".utf8)
    var t = RIPTerminal()
    t.files = MemoryRIPFiles(["A.ICN": specIcon])
    t.drawingBudget = 200_000
    for _ in 0..<50 {
        t.feed((0..<4000).map { _ in alphabet[Int(next()) % alphabet.count] })
    }
    var rounds = 0
    while t.hasPendingWork, rounds < 10_000 { t.feed([]); rounds += 1 }
    #expect(!t.hasPendingWork)
}

@Test func ripTextLayerUsesTheEGAFont() {
    #expect(RIPTerminal().font?.height == 14)
}
