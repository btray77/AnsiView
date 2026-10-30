import Foundation
import Testing
@testable import AnsiCore

@Test func oldEntriesLoadAsANSIBBSOverPlainTelnet() throws {
    let json = #"{"name":"Old","host":"bbs.example.com","port":23}"#
    let entry = try JSONDecoder().decode(BBSEntry.self, from: Data(json.utf8))
    #expect(entry.emulation == .ansiBBS)
    #expect(entry.telnetSecure == false)
}

@Test func emulationAndTLSRoundTrip() throws {
    var entry = BBSEntry(name: "C64", host: "c64.example.com")
    entry.emulation = .petscii64
    entry.telnetSecure = true
    let back = try JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(entry))
    #expect(back.emulation == .petscii64)
    #expect(back.telnetSecure)
}

@Test func unknownEmulationFallsBack() throws {
    let json = #"{"name":"X","host":"h","emulation":"teletype33"}"#
    let entry = try JSONDecoder().decode(BBSEntry.self, from: Data(json.utf8))
    #expect(entry.emulation == .ansiBBS)
}

@Test func emulationDefaults() {
    #expect(TerminalEmulation.petscii64.defaultColumns == 40 && TerminalEmulation.petscii64.defaultRows == 25)
    #expect(TerminalEmulation.atascii.defaultColumns == 40 && TerminalEmulation.atascii.defaultRows == 24)
    #expect(TerminalEmulation.viewdata.defaultColumns == 40 && TerminalEmulation.viewdata.defaultRows == 24)
    #expect(TerminalEmulation.petscii128.defaultColumns == 80)
    #expect(TerminalEmulation.ansiBBS.defaultColumns == 80 && TerminalEmulation.ansiBBS.defaultRows == 25)
    #expect(TerminalEmulation.vt220.defaultRows == 24)
    for e in TerminalEmulation.allCases {
        #expect(!e.terminalNames.isEmpty)
        #expect(!e.label.isEmpty)
    }
    #expect(TerminalEmulation.ansiBBS.terminalNames == BBSEntry.standardTerminalTypes)
}

@Test func choosingATypeInTheFormMovesDefaults() {
    var entry = BBSEntry(name: "A", host: "h")
    var form = EntryForm.make(entry: entry, password: "", fonts: BitmapFont.supportedNames, speeds: [0, 2400])
    let options = form.field("emulation")!.options
    #expect(options.first == "ANSI-BBS")
    form.setChoice("emulation", index: TerminalEmulation.allCases.firstIndex(of: .petscii64)!)
    entry = EntryForm.changingEmulation(form, draft: entry)
    #expect(entry.emulation == .petscii64)
    #expect(entry.columns == 40 && entry.rows == 25)
    #expect(entry.terminalType == TerminalEmulation.petscii64.terminalNames[0])
    #expect(entry.port == 23)
}

@Test func userChosenSizeIsKeptWhenTheTypeChanges() {
    var entry = BBSEntry(name: "A", host: "h")
    entry.columns = 132
    var form = EntryForm.make(entry: entry, password: "", fonts: BitmapFont.supportedNames, speeds: [0])
    form.setChoice("emulation", index: TerminalEmulation.allCases.firstIndex(of: .vt100)!)
    entry = EntryForm.changingEmulation(form, draft: entry)
    #expect(entry.columns == 132 && entry.rows == 24)
}

@Test func engineFactoryKeepsANSIBBSIdentical() {
    let stream = TerminalDigest.seededStream(seed: 1, length: 60_000)
    var engine = TerminalEngines.make(.ansiBBS, columns: 80, rows: 25, encoding: .cp437, iceColors: false)
    var i = 0
    while i < stream.count { engine.feed(Array(stream[i..<min(stream.count, i + 7)])); i += 7 }
    let plain = engine as? TerminalEmulator
    #expect(plain != nil)
    if let plain { #expect(TerminalDigest.digest(plain) == "f6a36c85af2de377a420df4b195791c46aa9143ca6d418b6150770a57c6f02a7") }
}

@Test func telnetSecureToggleMovesThePort() {
    var entry = BBSEntry(name: "A", host: "h")
    var form = EntryForm.make(entry: entry, password: "", fonts: BitmapFont.supportedNames, speeds: [0])
    form.setToggle("telnetSecure", on: true)
    entry = EntryForm.changingProtocol(form, draft: entry)
    #expect(entry.telnetSecure)
    #expect(entry.port == 992)
    #expect(TransportSettings(entry: entry).telnetSecure)
}

extension TextForm {
    mutating func setChoice(_ id: String, index: Int) {
        if let i = fields.firstIndex(where: { $0.id == id }) { fields[i].index = index }
    }
    mutating func setToggle(_ id: String, on: Bool) {
        if let i = fields.firstIndex(where: { $0.id == id }) { fields[i].isOn = on }
    }
}

extension FormField {
    var options: [String] {
        if case .choice(let list) = kind { return list }
        return []
    }
}
