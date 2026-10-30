import Foundation
import Testing
@testable import AnsiCore

private func row(_ cells: [AnsiCell]) -> AnsiScreen { AnsiScreen(columns: cells.count, rows: [cells]) }

/// The text inside the `pre` element.
private func preBody(_ html: String) -> String {
    let start = html.range(of: "<pre class=\"ansi\">")!.upperBound
    let end = html.range(of: "</pre>")!.lowerBound
    return String(html[start..<end])
}

@Test func runsMergeIntoSpans() {
    let red = AnsiCell(code: 0x41, fg: Palette.vga[4]), blue = AnsiCell(code: 0x42, fg: Palette.vga[1])
    let html = HTMLExport.document(row([red, red, red, blue, blue]), embedFont: false)
    #expect(preBody(html) == "<span class=\"f4\">AAA</span><span class=\"f1\">BB</span>\n")
}

@Test func escapesMarkup() {
    let cells = [0x3C, 0x26, 0x3E, 0x01, 0x1B, 0xDB].map { AnsiCell(code: UInt8($0)) }
    let body = preBody(HTMLExport.document(row(cells), embedFont: false))
    #expect(body == "&lt;&amp;&gt;☺←█\n")
    for scalar in body.unicodeScalars where scalar.value < 0x20 { #expect(scalar == "\n") }
}

@Test func classesUseVGAClasses() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41, fg: Palette.vga[12], bg: Palette.vga[1])]), embedFont: false)
    #expect(preBody(html) == "<span class=\"f12 b1\">A</span>\n")
    #expect(html.contains(".f12{color:#ff5555}"))
    #expect(html.contains(".b1{background:#0000aa}"))
}

@Test func otherColoursAreInline() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41, fg: RGB(r: 1, g: 2, b: 3))]), embedFont: false)
    #expect(preBody(html) == "<span style=\"color:#010203\">A</span>\n")
}

@Test func inlineUsesStyles() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41, fg: Palette.vga[12], bg: Palette.vga[1])]),
                                   style: .inline, embedFont: false)
    #expect(preBody(html) == "<span style=\"color:#ff5555;background:#0000aa\">A</span>\n")
    #expect(!html.contains(".f12"))
}

@Test func blinkClass() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41, blink: true)]), embedFont: false)
    #expect(preBody(html) == "<span class=\"blink\">A</span>\n")
    #expect(html.contains("@keyframes"))
}

@Test func embedsFontWithCredit() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41)]))
    #expect(html.contains("@font-face"))
    #expect(html.contains("base64,"))
    #expect(html.contains("CC BY-SA 4.0"))
    #expect(html.contains("font-size:16px"))
    #expect(HTMLExport.fontData(for: .vga)?.name == "Px437 IBM VGA 8x16")
}

@Test func noFontFallsBackToMonospace() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41)]), embedFont: false)
    #expect(!html.contains("@font-face"))
    #expect(html.contains("ui-monospace"))
}

@Test func titleIsEscaped() {
    let html = HTMLExport.document(row([AnsiCell(code: 0x41)]), embedFont: false, title: "A<B")
    #expect(html.contains("<title>A&lt;B</title>"))
}

@Test func dataForEachFormat() {
    let screen = row([AnsiCell(code: 0x41, fg: Palette.vga[12])])
    #expect(String(decoding: TextConvert.data(screen, format: .html), as: UTF8.self).hasPrefix("<!DOCTYPE html>"))
    #expect(TextConvert.data(screen, format: .text) == Data([0x41, 0x0D, 0x0A]))
    #expect(String(decoding: TextConvert.data(screen, format: .ansi256), as: UTF8.self) == "\u{1B}[38;5;9mA\u{1B}[0m\n")
}
