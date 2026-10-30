import Foundation
import Testing
@testable import AnsiCore

private func avatar(_ bytes: [UInt8], oneByteAtATime: Bool = false) -> AvatarTerminal {
    var t = AvatarTerminal(columns: 80, rows: 25)
    if oneByteAtATime { for b in bytes { t.feed([b]) } } else { t.feed(bytes) }
    return t
}

private func text(_ s: String) -> [UInt8] { Array(s.utf8) }

@Test func avatarAttributeAndText() {
    let t = avatar([0x16, 0x01, 0x1E] + text("Hi"))
    let cell = t.screen(scrollOffset: 0).rows[0][0]
    #expect(cell.code == 0x48)
    #expect(cell.fg == Palette.vga[14])
    #expect(cell.bg == Palette.vga[1])
}

@Test func avatarRepeatAndGoto() {
    let t = avatar([0x19, 0x41, 5, 0x16, 0x08, 3, 10, 0x42])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[0].prefix(6).map(\.code) == [0x41, 0x41, 0x41, 0x41, 0x41, 0x20])
    #expect(rows[2][9].code == 0x42)
}

@Test func avatarClearScreenResetsAttribute() {
    let t = avatar([0x16, 0x01, 0x4F] + text("X") + [0x0C] + text("Y"))
    let cell = t.screen(scrollOffset: 0).rows[0][0]
    #expect(cell.code == 0x59)
    #expect(cell.fg == Palette.vga[3])
    #expect(cell.bg == Palette.vga[0])
}

@Test func avatarCursorMovesAndClearToEnd() {
    let t = avatar(text("ABCDE") + [0x16, 0x05, 0x16, 0x05, 0x16, 0x07])
    #expect(t.screen(scrollOffset: 0).rows[0].prefix(5).map(\.code) == Array("ABC  ".utf8))
}

@Test func avtPlusRepeatPattern() {
    let t = avatar([0x16, 0x19, 2] + text("ab") + [3])
    #expect(t.screen(scrollOffset: 0).rows[0].prefix(7).map(\.code) == Array("ababab ".utf8))
}

@Test func avtPlusFillArea() {
    // ^V^M attr char lines columns: from the cursor.
    let t = avatar([0x16, 0x0D, 0x1F, 0x23, 2, 3])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[0].prefix(4).map(\.code) == [0x23, 0x23, 0x23, 0x20])
    #expect(rows[1].prefix(3).map(\.code) == [0x23, 0x23, 0x23])
    #expect(rows[1][0].bg == Palette.vga[1])
    #expect(rows[2][0].code == 0x20)
    #expect(t.cursor.row == 0 && t.cursor.column == 0)
}

@Test func avtPlusScrollAreaUp() {
    var bytes = text("11\r\n22\r\n33")
    bytes += [0x16, 0x0A, 1, 1, 1, 3, 2]
    let rows = avatar(bytes).screen(scrollOffset: 0).rows
    #expect(rows[0].prefix(3).map(\.code) == Array("22 ".utf8))
    #expect(rows[1].prefix(3).map(\.code) == Array("33 ".utf8))
    #expect(rows[2].prefix(2).map(\.code) == Array("  ".utf8))
}

@Test func avtPlusDeleteAndInsert() {
    let t = avatar(text("ABCD\r") + [0x16, 0x0E] + [0x16, 0x09] + text("X"))
    #expect(t.screen(scrollOffset: 0).rows[0].prefix(4).map(\.code) == Array("XBCD".utf8))
}

@Test func avatarSplitByteByByteMatchesWhole() {
    let bytes: [UInt8] = [0x16, 0x01, 0x1E] + text("Hello") + [0x19, 0x2A, 9, 0x16, 0x08, 5, 5] + [0x16, 0x19, 2] + text("xy")
        + [4, 0x16, 0x0D, 0x2F, 0x40, 2, 2] + text("\u{1B}[31mred")
    let whole = avatar(bytes).screen(scrollOffset: 0).rows
    let split = avatar(bytes, oneByteAtATime: true).screen(scrollOffset: 0).rows
    #expect(whole == split)
}

@Test func avatarPassesANSIThrough() {
    let t = avatar(text("\u{1B}[1;31mR"))
    #expect(t.screen(scrollOffset: 0).rows[0][0].fg == Palette.vga[12])
}

@Test func avatarRandomBytesDoNotCrash() {
    var state: UInt64 = 99
    var bytes: [UInt8] = []
    for _ in 0..<200_000 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let r = UInt8(truncatingIfNeeded: state >> 33)
        bytes.append(r % 7 == 0 ? 0x16 : (r % 11 == 0 ? 0x19 : r))
    }
    var t = AvatarTerminal(columns: 80, rows: 25)
    t.feed(bytes)
    #expect(t.screen(scrollOffset: 0).rows.count == 25)
}

@Test func engineFactoryMakesAvatar() {
    let e = TerminalEngines.make(.avatar, columns: 80, rows: 25, encoding: .cp437, iceColors: false)
    #expect(e is AvatarTerminal)
}
