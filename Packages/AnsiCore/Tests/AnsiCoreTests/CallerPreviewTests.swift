import Foundation
import Testing
@testable import AnsiCore

private func line(_ count: Int, _ ch: Character = "x") -> [UInt8] { Array(String(repeating: ch, count: count).utf8) }
private let crlf: [UInt8] = [0x0D, 0x0A]

@Test func displayTimeUsesTenBitsPerCharacter() {
    #expect(CallerPreviewAnalysis.displaySeconds(bytes: 2400, baud: 2400) == 10)
    #expect(CallerPreviewAnalysis.displaySeconds(bytes: 300, baud: 300) == 10)
    #expect(CallerPreviewAnalysis.displaySeconds(bytes: 11520, baud: 115200) == 1)
    #expect(CallerPreviewAnalysis.displaySeconds(bytes: 5000, baud: 0) == 0)
}

@Test func terminalSizePresets() {
    let labels = CallerTerminalSize.presets.map(\.label)
    #expect(labels == ["80 x 24", "80 x 25", "132 x 37"])
}

@Test func lineLongerThanWidthIsReported() {
    let stream = line(81) + crlf + line(10) + crlf
    let warnings = CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 25))
    #expect(warnings.contains { $0.kind == .lineTooLong && $0.row == 1 })
    #expect(!warnings.contains { $0.kind == .wrapAtLastColumn })
}

@Test func exactlyFullLineFollowedByNewlineIsAWrapRisk() {
    let stream = line(80) + crlf + line(3) + crlf
    let warnings = CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 25))
    #expect(warnings.map(\.kind) == [.wrapAtLastColumn])
    #expect(warnings.first?.row == 1)
}

@Test func escapeSequencesDoNotCountAsColumns() {
    let colour = Array("\u{1B}[1;33;44m".utf8)
    let stream = colour + line(40) + colour + line(39) + crlf
    #expect(CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 25)).isEmpty)
}

@Test func tallerThanScreenAndBottomRightCell() {
    var stream: [UInt8] = []
    for _ in 0..<30 { stream += line(5) + crlf }
    let tall = CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 24))
    #expect(tall.contains { $0.kind == .tallerThanScreen })

    // 24 lines where the last one fills the last column, with no newline after it.
    var exact: [UInt8] = []
    for _ in 0..<23 { exact += line(5) + crlf }
    exact += line(80)
    let corner = CallerPreviewAnalysis.layoutWarnings(exact, size: CallerTerminalSize(columns: 80, rows: 24))
    #expect(corner.map(\.kind) == [.bottomRightScroll])
}

@Test func newlineAfterLastScreenRowScrolls() {
    var stream: [UInt8] = []
    for _ in 0..<24 { stream += line(5) + crlf }
    let warnings = CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 24))
    #expect(warnings.contains { $0.kind == .tallerThanScreen })
}

@Test func cursorPositioningIsFollowed() {
    // ESC[25;80H then one character: the bottom right cell of an 80x25 screen.
    let stream = Array("\u{1B}[2J\u{1B}[25;80HX".utf8)
    let warnings = CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 25))
    #expect(warnings.map(\.kind) == [.bottomRightScroll])
}

@Test func sauceIsNotPartOfTheScreen() {
    let stream = line(10) + crlf + [0x1A] + Array("SAUCE00".utf8) + line(200)
    #expect(CallerPreviewAnalysis.layoutWarnings(stream, size: CallerTerminalSize(columns: 80, rows: 25)).isEmpty)
}
