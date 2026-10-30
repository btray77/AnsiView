import Foundation
import Testing
@testable import AnsiCore

private let esc = "\u{1B}"

private func vt(_ text: String, profile: TerminalProfile = .vt100, columns: Int = 80, rows: Int = 24) -> TerminalEmulator {
    var t = TerminalEmulator(columns: columns, rows: rows)
    t.profile = profile
    t.feed(Array(text.utf8))
    return t
}

@Test func decSpecialGraphicsDrawLines() {
    let t = vt("\(esc)(0lqkxmj\(esc)(Bq")
    #expect(t.grid[0].prefix(7).map(\.code) == [0xDA, 0xC4, 0xBF, 0xB3, 0xC0, 0xD9, 0x71])
}

@Test func ansiBBSStillIgnoresCharsetDesignation() {
    let t = vt("\(esc)(0lq", profile: .ansiBBS)
    #expect(t.grid[0].prefix(2).map(\.code) == [0x6C, 0x71])
}

@Test func shiftOutUsesG1() {
    let t = vt("\(esc))0a\u{0E}a\u{0F}a")
    #expect(t.grid[0].prefix(3).map(\.code) == [0x61, 0xB1, 0x61])
}

@Test func shiftOutInANSIBBSIsAGlyph() {
    let t = vt("\u{0E}", profile: .ansiBBS)
    #expect(t.grid[0][0].code == 0x0E)
}

@Test func decGraphicsWithoutCP437GlyphUsesScalar() {
    // 0x7C is "not equal to", which CP437 lacks.
    let t = vt("\(esc)(0|")
    #expect(t.grid[0][0].scalar == "\u{2260}")
}

@Test func ukCharsetPound() {
    let t = vt("\(esc)(A#")
    #expect(t.grid[0][0].code == 0x9C)
}

@Test func applicationCursorKeys() {
    var t = vt("\(esc)[?1h")
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1B, 0x4F, 0x41])
    t.feed(Array("\(esc)[?1l".utf8))
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1B, 0x5B, 0x41])
}

@Test func deviceAttributesPerProfile() {
    var a = vt("\(esc)[c")
    #expect(String(decoding: a.takeReplies(), as: UTF8.self) == "\(esc)[?1;2c")
    var b = vt("\(esc)[c", profile: .vt220)
    #expect(String(decoding: b.takeReplies(), as: UTF8.self) == "\(esc)[?62;1;6c")
    var c = vt("\(esc)[>c", profile: .vt220)
    #expect(String(decoding: c.takeReplies(), as: UTF8.self) == "\(esc)[>1;10;0c")
    var d = vt("\(esc)[c", profile: .ansiBBS)
    #expect(String(decoding: d.takeReplies(), as: UTF8.self) == "\(esc)[?1;0c")
}

@Test func originModePositionsInsideTheRegion() {
    let t = vt("\(esc)[5;10r\(esc)[?6h\(esc)[1;1HX")
    #expect(t.grid[4][0].code == 0x58)
    let u = vt("\(esc)[5;10r\(esc)[?6h\(esc)[20;1HY")
    #expect(u.grid[9][0].code == 0x59)
}

@Test func insertModeShiftsText() {
    let t = vt("ABC\r\(esc)[4hX\(esc)[4lY")
    #expect(t.grid[0].prefix(4).map(\.code) == Array("XYBC".utf8))
}

@Test func vtSplitAcrossFeeds() {
    var t = TerminalEmulator(columns: 80, rows: 24)
    t.profile = .vt100
    for byte in Array("\(esc)(0lq\(esc)(Bx".utf8) { t.feed([byte]) }
    #expect(t.grid[0].prefix(3).map(\.code) == [0xDA, 0xC4, 0x78])
}

@Test func engineFactoryMakesVTProfiles() {
    let e = TerminalEngines.make(.vt220, columns: 80, rows: 24, encoding: .utf8, iceColors: false)
    #expect((e as? TerminalEmulator)?.profile == .vt220)
}
