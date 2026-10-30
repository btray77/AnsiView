import Foundation
import Testing
@testable import AnsiCore

@Test func entryDefaults() {
    let entry = BBSEntry(name: "Example", host: "bbs.example.com")
    #expect(entry.port == 23)
    #expect(entry.columns == 80 && entry.rows == 25)
    #expect(entry.encoding == .cp437)
    #expect(entry.mode == .telnet)
    #expect(entry.baud == 0)
    #expect(entry.fontName == "IBM VGA")
    #expect(entry.username == nil)
    #expect(!entry.backspaceSendsDelete)
    #expect(entry.address == "bbs.example.com:23")
}

@Test func addressBookRoundTrip() {
    var second = BBSEntry(name: "Two", host: "10.0.0.2", port: 2323)
    second.username = "guest"
    second.encoding = .utf8
    second.mode = .raw
    second.baud = 9600
    second.columns = 132
    second.rows = 50
    second.fontName = "IBM EGA"
    second.backspaceSendsDelete = true
    let book = BBSAddressBook(entries: [BBSEntry(name: "One", host: "one.example.com"), second])
    #expect(BBSAddressBook(data: book.encoded()) == book)
}

@Test func badDataGivesEmptyBook() {
    #expect(BBSAddressBook(data: nil).entries.isEmpty)
    #expect(BBSAddressBook(data: Data("garbage".utf8)).entries.isEmpty)
    #expect(BBSAddressBook(data: Data("[]".utf8)).entries.isEmpty)
}

@Test func missingFieldsUseDefaults() throws {
    let json = #"[{"id":"9E2B1C1A-0000-4000-8000-000000000001","name":"Old","host":"old.example.com"}]"#
    let book = BBSAddressBook(data: Data(json.utf8))
    let entry = try #require(book.entries.first)
    #expect(entry.name == "Old" && entry.host == "old.example.com")
    #expect(entry.port == 23 && entry.columns == 80 && entry.rows == 25 && entry.mode == .telnet)
}

@Test func outOfRangeValuesAreClamped() throws {
    let json = #"[{"id":"9E2B1C1A-0000-4000-8000-000000000001","name":"X","host":"x","port":99999,"columns":0,"rows":900}]"#
    let entry = try #require(BBSAddressBook(data: Data(json.utf8)).entries.first)
    #expect(entry.port == 23)
    #expect(entry.columns == 1 && entry.rows == 255)
}

@Test func parseAddresses() {
    func check(_ text: String, _ host: String?, _ port: Int? = nil) {
        let parsed = BBSAddress.parse(text)
        #expect(parsed?.host == host, "\(text)")
        if let port { #expect(parsed?.port == port, "\(text)") }
    }
    check("host.example.com", "host.example.com", 23)
    check("host:2323", "host", 2323)
    check("telnet://host:2323/", "host", 2323)
    check("telnet://host", "host", 23)
    check("  host  ", "host", 23)
    check("[::1]:23", "::1", 23)
    check("::1", "::1", 23)
    check("host:0", nil)
    check("host:70000", nil)
    check("", nil)
    check("   ", nil)
    check("host:abc", nil)
    check("bad host", nil)
}
