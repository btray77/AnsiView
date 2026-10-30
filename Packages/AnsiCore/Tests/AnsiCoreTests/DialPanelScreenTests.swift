import Foundation
import Testing
@testable import AnsiCore

private func text(_ row: [AnsiCell]) -> String {
    String(row.map { Character(CP437.unicode[Int($0.code)]) })
}

private let status = DialPanelStatus(name: "Example BBS", address: "bbs.example.com:23", attempt: 2, passes: 3,
                                     position: 1, queueCount: 4, state: "Connecting", seconds: 7, waitFraction: nil)

@Test func dialPanelBoxAndTitle() {
    let screen = DialPanelScreen.make(status)
    #expect(screen.columns == DialPanelScreen.columns)
    #expect(screen.rows.count == DialPanelScreen.rows)
    #expect(screen.rows.allSatisfy { $0.count == DialPanelScreen.columns })
    #expect(screen.rows[0].first?.code == 0xC9 && screen.rows[0].last?.code == 0xBB)
    #expect(screen.rows.last?.first?.code == 0xC8 && screen.rows.last?.last?.code == 0xBC)
    #expect(text(screen.rows[0]).contains("AnsiView Dialer"))
    let all = screen.rows.map(text).joined(separator: "\n")
    #expect(all.contains("Example BBS"))
    #expect(all.contains("bbs.example.com:23"))
    #expect(all.contains("2 of 3"))
    #expect(all.contains("Connecting"))
    #expect(all.contains("2 of 4"))
    // Blue background inside the box.
    #expect(screen.rows[3][2].bg == Palette.vga[1])
}

@Test func dialPanelLongNamesTruncate() {
    var s = status
    s.name = String(repeating: "N", count: 200)
    let screen = DialPanelScreen.make(s)
    #expect(screen.rows.allSatisfy { $0.count == DialPanelScreen.columns })
    #expect(screen.rows[2].last?.code == 0xBA)
}

@Test func dialPanelWaitBarFills() {
    var s = status
    s.state = "Busy, redialing"
    s.waitFraction = 0.5
    let screen = DialPanelScreen.make(s)
    let bar = screen.rows.map(text).first { $0.contains("\u{2588}") || $0.contains("\u{2591}") } ?? ""
    let full = bar.filter { $0 == "\u{2588}" }.count
    let empty = bar.filter { $0 == "\u{2591}" }.count
    #expect(full > 0 && empty > 0)
    #expect(abs(full - empty) <= 1)
}
