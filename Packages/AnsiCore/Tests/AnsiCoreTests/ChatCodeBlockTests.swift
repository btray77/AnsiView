import Foundation
import Testing
@testable import AnsiCore

private func screen(_ cells: [AnsiCell], columns: Int = 10) -> AnsiScreen {
    var row = cells
    while row.count < columns { row.append(AnsiCell()) }
    return AnsiScreen(columns: columns, rows: [row])
}

/// Every SGR parameter list in the text, in order.
private func sgrLists(_ text: String) -> [[Int]] {
    var lists: [[Int]] = []
    var rest = Substring(text)
    while let start = rest.range(of: "\u{1B}[") {
        rest = rest[start.upperBound...]
        guard let end = rest.firstIndex(of: "m") else { break }
        lists.append(rest[..<end].split(separator: ";").compactMap { Int($0) })
        rest = rest[rest.index(after: end)...]
    }
    return lists
}

@Suite struct ChatCodeBlockTests {
    @Test func discordUsesOnlySupportedCodes() {
        var cells: [AnsiCell] = []
        for i in 0..<16 { cells.append(AnsiCell(code: 0xDB, fg: Palette.vga[i], bg: Palette.vga[15 - i])) }
        cells.append(AnsiCell(code: 0x41, fg: RGB(r: 12, g: 200, b: 99), bg: RGB(r: 70, g: 3, b: 140), blink: true))
        let text = ChatCodeBlock.discord(screen(cells, columns: 20))
        let allowed = Set([0, 1, 4] + Array(30...37) + Array(40...47))
        let used = Set(sgrLists(text).flatMap { $0 })
        #expect(!used.isEmpty)
        #expect(used.isSubset(of: allowed))
    }

    @Test func vgaColoursMapByHue() {
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[4], bg: Palette.vga[0]) == [31])
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[12], bg: Palette.vga[0]) == [1, 31])
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[1], bg: Palette.vga[0]) == [34])
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[14], bg: Palette.vga[2]) == [1, 33, 42])
        // Light grey is Discord's own text colour; white is bold white.
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[7], bg: Palette.vga[0]) == [])
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[15], bg: Palette.vga[0]) == [1, 37])
    }

    @Test func blackBackgroundIsDefault() {
        let codes = ChatCodeBlock.discordCodes(fg: Palette.vga[2], bg: Palette.vga[0])
        #expect(!codes.contains { (40...47).contains($0) })
        // A bright (iCE) background uses the same hue.
        #expect(ChatCodeBlock.discordCodes(fg: Palette.vga[7], bg: Palette.vga[9]) == [44])
    }

    @Test func trueColourGoesToNearestVGA() {
        #expect(ChatCodeBlock.nearestVGA(RGB(r: 250, g: 80, b: 90)) == 12)
        #expect(ChatCodeBlock.nearestVGA(RGB(r: 0, g: 0, b: 160)) == 1)
        #expect(ChatCodeBlock.nearestVGA(Palette.vga[6]) == 6)
    }

    @Test func codesOnlyOnChange() {
        let red = AnsiCell(code: 0xDB, fg: Palette.vga[4])
        let text = ChatCodeBlock.discord(screen([red, red, red, AnsiCell(code: 0x41, fg: Palette.vga[2])]))
        // One code for the three red blocks, one for the green A, one reset at the line end.
        #expect(sgrLists(text) == [[0, 31], [0, 32], [0]])
        #expect(text.contains("\u{2588}\u{2588}\u{2588}"))
    }

    @Test func fencedAsAnsi() {
        let text = ChatCodeBlock.discord(screen([AnsiCell(code: 0x48, fg: Palette.vga[4]), AnsiCell(code: 0x49)]))
        #expect(text.hasPrefix("```ansi\n"))
        #expect(text.hasSuffix("\n```"))
        // Real escape characters, not a written \u001b.
        #expect(text.contains("\u{1B}[0;31mH"))
    }

    @Test func slackIsPlainFence() {
        let text = ChatCodeBlock.slack(screen([AnsiCell(code: 0xDB, fg: Palette.vga[4]), AnsiCell(code: 0x48)]))
        #expect(text == "```\n\u{2588}H\n```")
        #expect(!text.contains("\u{1B}"))
    }

    @Test func blankLinesKeptInsideTrailingTrimmed() {
        let rows = [[AnsiCell(code: 0x41)], [AnsiCell()], [AnsiCell(code: 0x42)], [AnsiCell()]]
        let text = ChatCodeBlock.slack(AnsiScreen(columns: 1, rows: rows))
        #expect(text == "```\nA\n\nB\n```")
    }

    @Test func backticksCannotCloseTheFence() {
        let tick = AnsiCell(code: UInt8(ascii: "`"))
        let text = ChatCodeBlock.slack(screen([tick, tick, tick]))
        #expect(text.components(separatedBy: "```").count == 3)  // only the opening and closing fences
    }

    @Test func characterCountAndLimit() {
        let text = ChatCodeBlock.slack(screen([AnsiCell(code: 0x41)]))
        #expect(ChatCodeBlock.characterCount(text) == 9)
        #expect(ChatCodeBlock.discordLimit == 2000)
    }
}

@Suite struct ChatClipboardTests {
    @Test func discordAndSlackCopiesAreText() {
        let clip = CellClipboard(region: CanvasRegion(cells: [[AnsiCell(code: 0xDB, fg: Palette.vga[4])]]))
        let discord = clip.immediateRepresentations(.discord)
        #expect(discord.map(\.type) == [CellClipboard.textType])
        #expect(String(decoding: discord[0].data, as: UTF8.self) == "```ansi\n\u{1B}[0;31m\u{2588}\u{1B}[0m\n```")
        let slack = clip.immediateRepresentations(.slack)
        #expect(String(decoding: slack[0].data, as: UTF8.self) == "```\n\u{2588}\n```")
        #expect(clip.deferredImageTypes(.discord).isEmpty)
    }
}
