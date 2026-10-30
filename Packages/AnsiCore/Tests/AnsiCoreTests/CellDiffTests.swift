import Foundation
import Testing
@testable import AnsiCore

struct CellDiffTests {
    func screen(_ text: String) -> AnsiScreen {
        AnsiAnalysis(ArtFile(data: Data(text.utf8), fileExtension: "ans")).finalScreen
    }

    @Test func identicalScreensHaveNoDifferences() {
        let diff = CellDiff(screen("HELLO\r\nWORLD"), screen("HELLO\r\nWORLD"))
        #expect(diff.count == 0)
        #expect(diff.total == 160)
        #expect(diff.rowsWithDifferences.isEmpty)
    }

    @Test func oneChangedCell() {
        let diff = CellDiff(screen("HELLO\r\nWORLD"), screen("HELLO\r\nWORLD\u{1B}[1;1H\u{1B}[31mH"))
        #expect(diff.count == 1)
        #expect(diff.differs(x: 0, y: 0))
        #expect(!diff.differs(x: 1, y: 0))
        #expect(diff.rowsWithDifferences == [0])
    }

    @Test func blankForegroundIgnored() {
        // A red space looks the same as a grey one; NUL and 255 draw as spaces.
        var a = AnsiScreen(columns: 3, rows: [[AnsiCell(code: 0x20), AnsiCell(code: 0x00), AnsiCell(code: 0xFF)]])
        let b = AnsiScreen(columns: 3, rows: [[AnsiCell(code: 0x20, fg: Palette.vga[4]), AnsiCell(code: 0x20), AnsiCell(code: 0x20)]])
        #expect(CellDiff(a, b).count == 0)
        a.rows[0][0].bg = Palette.vga[1]
        #expect(CellDiff(a, b).count == 1)
        #expect(CellDiff.sameLook(AnsiCell(code: 0x41), AnsiCell(code: 0x41, blink: true)) == false)
    }

    @Test func sizeMismatchCountsExtraCells() {
        let a = AnsiScreen(columns: 2, rows: [[AnsiCell(code: 0x41), AnsiCell(code: 0x42)]])
        let b = AnsiScreen(columns: 3, rows: [[AnsiCell(code: 0x41), AnsiCell(code: 0x42), AnsiCell(code: 0x43)],
                                             [AnsiCell(), AnsiCell(), AnsiCell()]])
        let diff = CellDiff(a, b)
        #expect(diff.columns == 3)
        #expect(diff.rows == 2)
        #expect(diff.count == 4)
        #expect(diff.differs(x: 2, y: 0))
        #expect(diff.differs(x: 0, y: 1))
    }

    @Test func stepsThroughDifferingRowsWrapping() {
        var rows = (0..<10).map { _ in [AnsiCell(code: 0x41)] }
        let a = AnsiScreen(columns: 1, rows: rows)
        rows[2][0].code = 0x42
        rows[7][0].code = 0x42
        let diff = CellDiff(a, AnsiScreen(columns: 1, rows: rows))
        #expect(diff.nextRow(after: nil, forward: true) == 2)
        #expect(diff.nextRow(after: 2, forward: true) == 7)
        #expect(diff.nextRow(after: 7, forward: true) == 2)
        #expect(diff.nextRow(after: 2, forward: false) == 7)
        #expect(diff.nextRow(after: nil, forward: false) == 7)
        #expect(CellDiff(a, a).nextRow(after: nil, forward: true) == nil)
    }
}
