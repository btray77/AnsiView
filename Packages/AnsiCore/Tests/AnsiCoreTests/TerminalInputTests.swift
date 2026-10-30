import Testing
@testable import AnsiCore

private func seq(_ text: String) -> [UInt8] { Array(text.utf8) }

@Test func keySequences() {
    let expected: [(TerminalKey, [UInt8])] = [
        (.returnKey, [13]), (.tab, [9]), (.escape, [27]),
        (.up, seq("\u{1B}[A")), (.down, seq("\u{1B}[B")), (.right, seq("\u{1B}[C")), (.left, seq("\u{1B}[D")),
        (.home, seq("\u{1B}[1~")), (.insert, seq("\u{1B}[2~")), (.forwardDelete, seq("\u{1B}[3~")),
        (.end, seq("\u{1B}[4~")), (.pageUp, seq("\u{1B}[5~")), (.pageDown, seq("\u{1B}[6~")),
        (.function(1), [27, 79, 80]), (.function(2), [27, 79, 81]), (.function(3), [27, 79, 82]),
        (.function(4), [27, 79, 83]), (.function(5), seq("\u{1B}[15~")), (.function(6), seq("\u{1B}[17~")),
        (.function(7), seq("\u{1B}[18~")), (.function(8), seq("\u{1B}[19~")), (.function(9), seq("\u{1B}[20~")),
        (.function(10), seq("\u{1B}[21~")), (.function(11), seq("\u{1B}[23~")), (.function(12), seq("\u{1B}[24~")),
    ]
    for (key, bytes) in expected {
        #expect(TerminalInput.bytes(for: key, backspaceSendsDelete: false) == bytes, "\(key)")
    }
    #expect(TerminalInput.bytes(for: .function(13), backspaceSendsDelete: false).isEmpty)
}

@Test func backspaceConfigurable() {
    #expect(TerminalInput.bytes(for: .backspace, backspaceSendsDelete: false) == [8])
    #expect(TerminalInput.bytes(for: .backspace, backspaceSendsDelete: true) == [127])
}

@Test func cp437TextEncoding() {
    #expect(TerminalInput.text("A░é€", encoding: .cp437) == [65, 176, 130])
    #expect(TerminalInput.text("╔═╗", encoding: .cp437) == [201, 205, 187])
}

@Test func utf8TextEncoding() {
    #expect(TerminalInput.text("░", encoding: .utf8) == [0xE2, 0x96, 0x91])
}

@Test func pasteNewlinesBecomeCR() {
    #expect(TerminalInput.text("a\r\nb\nc\rd", encoding: .cp437) == [97, 13, 98, 13, 99, 13, 100])
}

@Test func controlLetters() {
    #expect(TerminalInput.control("a") == [1])
    #expect(TerminalInput.control("Z") == [26])
    #expect(TerminalInput.control("[") == [27])
    #expect(TerminalInput.control("1") == nil)
}
