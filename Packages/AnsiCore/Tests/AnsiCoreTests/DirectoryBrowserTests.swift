import Foundation
import Testing
@testable import AnsiCore

private func lines(_ screen: AnsiScreen) -> [String] {
    screen.rows.map { String($0.map { Character(CP437.unicode[Int($0.code)]) }) }
}

private func directory() -> DialingDirectory {
    var a = BBSEntry(name: "Charlie Board", host: "c.example.com")
    a.tags = ["Favourites"]
    a.totalCalls = 3
    var b = BBSEntry(name: "Alpha Board", host: "a.example.com", port: 2323)
    b.notes = "Trade Wars every night"
    b.tags = ["Trade Wars games"]
    var c = BBSEntry(name: "Bravo Board", host: "b.example.com")
    c.tags = ["favourites"]
    c.totalCalls = 9
    return DialingDirectory(entries: [a, b, c])
}

@Test func browserNavigatesAndDials() {
    let dir = directory()
    var br = DirectoryBrowser()
    #expect(br.visible(in: dir).map(\.name) == ["Charlie Board", "Alpha Board", "Bravo Board"])
    #expect(br.handle(.enter, in: dir) == .dial([dir.entries[0].id]))
    _ = br.handle(.down, in: dir)
    #expect(br.handle(.enter, in: dir) == .dial([dir.entries[1].id]))
    _ = br.handle(.end, in: dir)
    #expect(br.selectedID(in: dir) == dir.entries[2].id)
    _ = br.handle(.down, in: dir)
    #expect(br.selectedID(in: dir) == dir.entries[2].id)
    _ = br.handle(.home, in: dir)
    #expect(br.selectedID(in: dir) == dir.entries[0].id)
}

@Test func browserMarksQueueInListOrder() {
    let dir = directory()
    var br = DirectoryBrowser()
    _ = br.handle(.end, in: dir)
    _ = br.handle(.character(" "), in: dir)
    _ = br.handle(.home, in: dir)
    _ = br.handle(.character(" "), in: dir)
    #expect(Set(br.marked) == [dir.entries[0].id, dir.entries[2].id])
    // Space also moves down, as in classic phone books.
    #expect(br.selectedID(in: dir) == dir.entries[1].id)
    #expect(br.handle(.enter, in: dir) == .dial([dir.entries[0].id, dir.entries[2].id]))
    #expect(br.handle(.character("d"), in: dir) == .delete([dir.entries[0].id, dir.entries[2].id]))
    _ = br.handle(.character("u"), in: dir)
    #expect(br.marked.isEmpty)
    #expect(br.handle(.forwardDelete, in: dir) == .delete([dir.entries[1].id]))
}

@Test func browserHotkeys() {
    let dir = directory()
    var br = DirectoryBrowser()
    #expect(br.handle(.character("n"), in: dir) == .new)
    #expect(br.handle(.character("E"), in: dir) == .edit(dir.entries[0].id))
    #expect(br.handle(.character("c"), in: dir) == .duplicate(dir.entries[0].id))
    #expect(br.handle(.character("g"), in: dir) == .settings)
    #expect(br.handle(.character("i"), in: dir) == .importFile)
    #expect(br.handle(.character("x"), in: dir) == .exportFile)
    #expect(br.handle(.escape, in: dir) == .close)
    #expect(br.handle(.character("z"), in: dir) == DirectoryBrowser.Event.none)
}

@Test func browserSortCycle() {
    let dir = directory()
    var br = DirectoryBrowser()
    _ = br.handle(.character("s"), in: dir)
    #expect(br.sort == .name)
    #expect(br.visible(in: dir).map(\.name) == ["Alpha Board", "Bravo Board", "Charlie Board"])
    _ = br.handle(.character("s"), in: dir)
    #expect(br.sort == .address)
    _ = br.handle(.character("s"), in: dir)
    #expect(br.sort == .lastCalled)
    _ = br.handle(.character("s"), in: dir)
    #expect(br.sort == .totalCalls)
    #expect(br.visible(in: dir).map(\.name) == ["Bravo Board", "Charlie Board", "Alpha Board"])
    _ = br.handle(.character("s"), in: dir)
    #expect(br.sort == nil)
}

@Test func browserTagFilterAndSearch() {
    let dir = directory()
    var br = DirectoryBrowser()
    _ = br.handle(.character("t"), in: dir)
    #expect(br.tag == "Favourites")
    #expect(br.visible(in: dir).map(\.name) == ["Charlie Board", "Bravo Board"])
    _ = br.handle(.character("t"), in: dir)
    #expect(br.tag == "Trade Wars games")
    _ = br.handle(.character("t"), in: dir)
    #expect(br.tag == nil)
    _ = br.handle(.character("/"), in: dir)
    #expect(br.searching)
    for c in "trade" { _ = br.handle(.character(c), in: dir) }
    #expect(br.visible(in: dir).map(\.name) == ["Alpha Board"])
    // Letters typed while searching are not hotkeys.
    #expect(br.search == "trade")
    _ = br.handle(.enter, in: dir)
    #expect(!br.searching && br.search == "trade")
    #expect(br.handle(.enter, in: dir) == .dial([dir.entries[1].id]))
    _ = br.handle(.character("/"), in: dir)
    _ = br.handle(.escape, in: dir)
    #expect(br.search.isEmpty && !br.searching)
}

@Test func browserReorders() {
    let dir = directory()
    var br = DirectoryBrowser()
    _ = br.handle(.down, in: dir)
    #expect(br.handle(.moveUp, in: dir) == .reorder([dir.entries[1].id], before: dir.entries[0].id))
    #expect(br.handle(.moveDown, in: dir) == .reorder([dir.entries[1].id], before: nil))
    _ = br.handle(.home, in: dir)
    #expect(br.handle(.moveDown, in: dir) == .reorder([dir.entries[0].id], before: dir.entries[2].id))
    #expect(br.handle(.moveUp, in: dir) == DirectoryBrowser.Event.none)
    // Not while sorted: the status line says why.
    _ = br.handle(.character("s"), in: dir)
    #expect(br.handle(.moveDown, in: dir) == DirectoryBrowser.Event.none)
    #expect(br.message.contains("Manual"))
    // Dragging a row onto another moves it before that row.
    var manual = DirectoryBrowser()
    #expect(manual.drag(from: 2, to: 0, in: dir) == .reorder([dir.entries[2].id], before: dir.entries[0].id))
    #expect(manual.drag(from: 0, to: 2, in: dir) == .reorder([dir.entries[0].id], before: nil))
    #expect(manual.drag(from: 1, to: 1, in: dir) == DirectoryBrowser.Event.none)
}

@Test func browserScreen() throws {
    let dir = directory()
    var br = DirectoryBrowser()
    _ = br.handle(.character(" "), in: dir)
    let rendered = br.screen(in: dir, columns: 80, rows: 25)
    let text = lines(rendered.screen)
    #expect(rendered.screen.rows.count == 25 && rendered.screen.rows.allSatisfy { $0.count == 80 })
    #expect(text[0].contains("Dialing Directory"))
    #expect(text.contains { $0.contains("Name") && $0.contains("Address") && $0.contains("Calls") })
    let alphaRow = try #require(text.firstIndex { $0.contains("Alpha Board") })
    #expect(text[alphaRow].contains("a.example.com:2323"))
    #expect(rendered.entryAtRow[alphaRow] == 1)
    // The selected row is a highlight bar; the marked row shows a check mark.
    #expect(rendered.screen.rows[alphaRow].contains { $0.bg == Palette.vga[3] })
    let charlieRow = try #require(text.firstIndex { $0.contains("Charlie Board") })
    #expect(rendered.screen.rows[charlieRow].contains { $0.code == 0xFB })
    // The selected entry's notes, and the keys.
    #expect(text.contains { $0.contains("Trade Wars every night") })
    #expect(text[24].contains("Esc") || text[23].contains("Esc"))
    let empty = lines(br.screen(in: DialingDirectory(), columns: 80, rows: 25).screen)
    #expect(empty.contains { $0.contains("No BBSes") })
}

@Test func browserClick() {
    let dir = directory()
    var br = DirectoryBrowser()
    let rendered = br.screen(in: dir, columns: 80, rows: 25)
    let row = rendered.entryAtRow.first { $0.value == 2 }!.key
    #expect(br.click(row: row, count: 1, map: rendered.entryAtRow, in: dir) == DirectoryBrowser.Event.none)
    #expect(br.selectedID(in: dir) == dir.entries[2].id)
    #expect(br.click(row: row, count: 2, map: rendered.entryAtRow, in: dir) == .dial([dir.entries[2].id]))
}

@Test func browserScrollsLongLists() {
    let dir = DialingDirectory(entries: (0..<60).map { BBSEntry(name: "Board \($0)", host: "h\($0).example.com") })
    var br = DirectoryBrowser()
    _ = br.handle(.end, in: dir)
    let rendered = br.screen(in: dir, columns: 80, rows: 25)
    #expect(rendered.entryAtRow.values.contains(59))
    #expect(!rendered.entryAtRow.values.contains(0))
    _ = br.handle(.pageUp, in: dir)
    #expect(br.selectedID(in: dir) != dir.entries[59].id)
}
