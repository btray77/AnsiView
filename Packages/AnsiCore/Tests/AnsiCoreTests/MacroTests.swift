import Foundation
import Testing
@testable import AnsiCore

@Test func macroEscapes() {
    #expect(MacroText.bytes("a\\rb\\nc\\td\\e[0m\\\\", encoding: .cp437) == [97, 13, 98, 10, 99, 9, 100, 27, 91, 48, 109, 92])
    // A real newline typed in the field is a CR, as Return would be.
    #expect(MacroText.bytes("x\ny", encoding: .cp437) == [120, 13, 121])
}

@Test func macroHexEscapes() {
    #expect(MacroText.bytes("\\x41\\x1b\\xFF", encoding: .cp437) == [0x41, 0x1B, 0xFF])
}

@Test func badEscapesSentAsTyped() {
    #expect(MacroText.bytes("\\q\\x4\\xZZ\\", encoding: .cp437) == Array("\\q\\x4\\xZZ\\".utf8))
}

@Test func macroEncodingApplied() {
    #expect(MacroText.bytes("é░", encoding: .cp437) == [130, 176])
    #expect(MacroText.bytes("é", encoding: .utf8) == [0xC3, 0xA9])
}

@Test func entryOverridesGlobal() {
    var e = BBSEntry(name: "x", host: "x")
    var global = Array(repeating: "", count: MacroSet.slotCount)
    global[0] = "global one"
    global[1] = "global two"
    e.macros[1] = "entry two"
    #expect(MacroSet.text(slot: 0, entry: e, global: global) == "global one")
    #expect(MacroSet.text(slot: 1, entry: e, global: global) == "entry two")
    #expect(MacroSet.text(slot: 2, entry: e, global: global) == nil)
    #expect(MacroSet.text(slot: 99, entry: e, global: global) == nil)
    // Short arrays (hand edited JSON) do not crash.
    e.macros = []
    #expect(MacroSet.text(slot: 1, entry: e, global: []) == nil)
}

@Test func digitSlots() {
    #expect(MacroSet.slot(forDigit: "1") == 0)
    #expect(MacroSet.slot(forDigit: "9") == 8)
    #expect(MacroSet.slot(forDigit: "0") == 9)
    #expect(MacroSet.slot(forDigit: "a") == nil)
    #expect(MacroSet.label(slot: 9) == "Option-0")
}
