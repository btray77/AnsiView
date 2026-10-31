import Foundation
import Testing
@testable import AnsiCore

// Findings of the final review of the terminal gaps branch.

@Test func bbcModeSurvivesAResize() {
    var t = TeletextTerminal(flavour: .mode7)
    t.feed([22, 0] + Array("TOP".utf8))
    t.resize(columns: 80, rows: 40)
    let screen = t.screen(scrollOffset: 0)
    #expect(screen.rows.count == 40)
    #expect(screen.rows[0][0].code == UInt8(ascii: "T"))
    t.resize(columns: 20, rows: 10)
    #expect(t.screen(scrollOffset: 0).rows.count == 10)
}

@Test func bbcRelativePlotsCannotOverflow() {
    var t = TeletextTerminal(flavour: .mode7)
    var bytes: [UInt8] = [22, 0]
    for _ in 0..<300_000 { bytes += [25, 0, 0xFF, 0x7F, 0x00, 0x80] }
    bytes += [25, 4, 0, 0, 0, 0, 25, 85, 0, 2, 0, 2]
    t.feed(bytes)
    #expect(t.bbcMode == 0)
}

private func seconds(_ work: () -> Void) -> Double {
    let start = Date()
    work()
    return Date().timeIntervalSince(start)
}

@Test func longRIPTextBlockLinesAreQuick() {
    var t = RIPTerminal()
    let line = "!|Y01000A|1T0000010100|1t0" + String(repeating: "W", count: 16000) + "\r\n"
    #expect(seconds { t.feed(Array(line.utf8)) } < 1.0)
}

@Test func hugeStrokeTextIsBounded() {
    var t = RIPTerminal()
    let line = "!|Y0A000A|@0000" + String(repeating: "W", count: 16000) + "\r\n"
    t.feed(Array(line.utf8))
    #expect(t.canvas.work < 50_000_000)
}

@Test func sixelRepeatFloodIsBounded() {
    var body = Array("q#1".utf8)
    for _ in 0..<300_000 { body += Array("!4096~$".utf8) }   // 2 MB: 7 G pixel writes asked for
    #expect(seconds { _ = SixelDecoder.decode(body) } < 30.0)
}

@Test func placedImagesHaveIdsAndAreCapped() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array("\u{1B}[5;10r".utf8))
    for _ in 0..<500 { t.feed(Array("\u{1B}[6;1H\u{1B}Pq#1~\u{1B}\\".utf8)) }
    let images = t.images(scrollOffset: 0)
    #expect(images.count <= TerminalImageLimits.maxImages)
    #expect(Set(images.map(\.id)).count == images.count)
    // A picture fully covered by a newer one is dropped.
    var u = TerminalEmulator(columns: 80, rows: 25)
    u.feed(Array("\u{1B}[H\u{1B}Pq#1~\u{1B}\\\u{1B}[H\u{1B}Pq#2~\u{1B}\\".utf8))
    #expect(u.images(scrollOffset: 0).count == 1)
}

@Test func reloadedCTermFontIsANewFont() {
    let a = Data([UInt8](repeating: 0, count: 2048)).base64EncodedString()
    let b = Data([UInt8](repeating: 0xFF, count: 2048)).base64EncodedString()
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array("\u{1B}PCTerm:Font:43:\(a)\u{1B}\\\u{1B}[0;43 D".utf8))
    let first = t.font?.name
    t.feed(Array("\u{1B}PCTerm:Font:43:\(b)\u{1B}\\\u{1B}[0;43 D".utf8))
    #expect(t.font?.name != first)
}

@Test func hostileRIPFileOpensQuickly() {
    let line = "!|Y0A000A|@0000" + String(repeating: "W", count: 2000) + "\r\n"
    let data = Data(String(repeating: line, count: 40).utf8)
    // Counted in pixels drawn, not seconds (a loaded machine makes timings meaningless): each
    // round stays near its budget and the file stops after a fixed number of rounds.
    var t = RIPTerminal()
    t.drawingBudget = ArtFile.ripRoundBudget
    t.feed([UInt8](data))
    var works = [t.canvas.work]
    while t.hasPendingWork, works.count <= ArtFile.ripRounds { t.feed([]); works.append(t.canvas.work) }
    #expect(works.allSatisfy { $0 < ArtFile.ripRoundBudget + 2_000_000 })
    _ = ArtFile(data: data, fileExtension: "rip")
}
