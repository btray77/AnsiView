import Foundation
import Testing
@testable import AnsiCore

private func fixture() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "syncterm", withExtension: "lst", subdirectory: "Fixtures/syncterm"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func syncTermImportsTelnetAndRaw() throws {
    let result = SyncTermImport.parse(try fixture())
    #expect(result.entries.map(\.entry.name) == ["Example Telnet Board", "Raw Socket Board", "Default Port Board"])
    let first = result.entries[0].entry
    #expect(first.host == "telnet.example.com" && first.port == 2323 && first.mode == .telnet)
    #expect(first.username == "guest")
    #expect(first.notes == "Door games and message bases")
    let raw = result.entries[1].entry
    #expect(raw.host == "raw.example.org" && raw.mode == .raw && raw.port == 23)
    #expect(result.entries[2].entry.mode == .telnet)
}

@Test func syncTermSkipsOtherTypes() throws {
    let result = SyncTermImport.parse(try fixture())
    // SSH, Modem, and an entry with no address.
    #expect(result.skipped == ["Secure Board (SSH)", "Old Modem Entry (Modem)", "Broken Entry (no address)"])
}

@Test func syncTermPasswordsReturnedSeparately() throws {
    let result = SyncTermImport.parse(try fixture())
    #expect(result.entries[0].password == "fixture-pass")
    #expect(result.entries[1].password == nil)
    // The entry itself can never carry it.
    let json = String(decoding: DialingDirectory(entries: result.entries.map(\.entry)).encoded(), as: UTF8.self)
    #expect(!json.contains("fixture-pass"))
}

@Test func syncTermScreenModeAndBps() throws {
    let result = SyncTermImport.parse(try fixture())
    let first = result.entries[0].entry
    #expect(first.columns == 80 && first.rows == 50 && first.baud == 2400)
    let last = result.entries[2].entry
    #expect(last.columns == 132 && last.rows == 37 && last.baud == 0)
}

@Test func syncTermToleratesCommentsAndBlankLines() {
    let text = "\u{FEFF}; comment\r\n# another\r\n\r\n[Only]\r\n  address=only.example.com  \r\n  port=bogus\r\nconnectiontype=TELNET\r\n"
    let result = SyncTermImport.parse(text)
    #expect(result.entries.count == 1)
    #expect(result.entries[0].entry.host == "only.example.com")
    #expect(result.entries[0].entry.port == 23)
    // A section with no connection type is telnet (SyncTERM's default).
    #expect(SyncTermImport.parse("[N]\nAddress=n.example.com\n").entries.first?.entry.mode == .telnet)
    #expect(SyncTermImport.parse("").entries.isEmpty)
}
