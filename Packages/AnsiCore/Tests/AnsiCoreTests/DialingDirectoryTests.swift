import Foundation
import Testing
@testable import AnsiCore

private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

private func entry(_ name: String, _ host: String, port: Int = 23, user: String? = nil, tags: [String] = [],
                   notes: String = "") -> BBSEntry {
    var e = BBSEntry(name: name, host: host, port: port)
    e.username = user
    e.tags = tags
    e.notes = notes
    return e
}

@Test func newEntryDefaults() {
    let e = BBSEntry(name: "X", host: "x.example.com")
    #expect(e.notes.isEmpty && e.tags.isEmpty)
    #expect(e.lastCalled == nil && e.totalCalls == 0)
    #expect(!e.captureOnConnect && e.captureFolderBookmark == nil && e.captureFolderName == nil)
    #expect(e.modemSound == .playbackSetting)
    #expect(e.macros == Array(repeating: "", count: MacroSet.slotCount))
    #expect(e.autoLogin)
    #expect(e.loginScript == LoginScript.defaultSteps)
    #expect(e.busyText.contains("all nodes are busy"))
}

@Test func plan7EntryDecodesWithNewDefaults() throws {
    // Exactly what plan 7's encoder wrote.
    let json = #"[{"id":"9E2B1C1A-0000-4000-8000-000000000001","name":"Old","host":"old.example.com","port":2323,"username":"sysop","fontName":"IBM EGA","columns":80,"rows":50,"encoding":"utf8","mode":"raw","baud":9600,"backspaceSendsDelete":true}]"#
    let dir = DialingDirectory(stored: nil, legacy: Data(json.utf8))
    let e = try #require(dir.entries.first)
    #expect(dir.entries.count == 1)
    #expect(e.id == UUID(uuidString: "9E2B1C1A-0000-4000-8000-000000000001"))
    #expect(e.port == 2323 && e.username == "sysop" && e.fontName == "IBM EGA" && e.rows == 50)
    #expect(e.encoding == .utf8 && e.mode == .raw && e.baud == 9600 && e.backspaceSendsDelete)
    #expect(e.totalCalls == 0 && e.tags.isEmpty && e.autoLogin)
}

@Test func directoryRoundTrip() {
    var a = entry("One", "one.example.com", user: "me", tags: ["Favourites"], notes: "Door games")
    a.lastCalled = fixedDate
    a.totalCalls = 7
    a.captureOnConnect = true
    a.captureFolderBookmark = Data([1, 2, 3])
    a.captureFolderName = "Captures"
    a.modemSound = .on
    a.macros[0] = "hello\\r"
    a.loginScript = [LoginStep(expect: "who:", send: .text, text: "x\\r", timeout: 5)]
    a.busyText = "go away"
    var dir = DialingDirectory(entries: [a, entry("Two", "two.example.com", port: 2323)])
    dir.globalMacros[3] = "/q\\r"
    dir.showAtLaunch = true
    dir.redialAttempts = 5
    dir.redialDelay = 30
    let back = DialingDirectory(stored: dir.encoded(), legacy: nil)
    #expect(back == dir)
}

@Test func migratesPlan7Book() {
    let old = BBSAddressBook(entries: [entry("A", "a.example.com"), entry("B", "b.example.com", port: 2323)])
    let dir = DialingDirectory(stored: nil, legacy: old.encoded())
    #expect(dir.entries.map(\.name) == ["A", "B"])
    #expect(dir.entries.map(\.id) == old.entries.map(\.id))
}

@Test func existingDirectoryWins() {
    let old = BBSAddressBook(entries: [entry("Old", "old.example.com")])
    let current = DialingDirectory(entries: [entry("New", "new.example.com")])
    let dir = DialingDirectory(stored: current.encoded(), legacy: old.encoded())
    #expect(dir.entries.map(\.name) == ["New"])
}

@Test func emptyDefaultsGiveExample() {
    let dir = DialingDirectory(stored: nil, legacy: nil)
    #expect(dir.entries.count == 1)
    #expect(dir.entries[0].host == "bbs.example.com")
    #expect(dir.entries[0].name.lowercased().contains("example"))
}

@Test func unreadableDirectoryIsEmptyNotExample() {
    #expect(DialingDirectory(stored: Data("garbage".utf8), legacy: nil).entries.isEmpty)
    // An empty plan 7 book stays empty too.
    #expect(DialingDirectory(stored: nil, legacy: Data("[]".utf8)).entries.isEmpty)
}

@Test func searchAndTags() {
    let dir = DialingDirectory(entries: [
        entry("Trade Wars Haven", "tw.example.com", tags: ["Trade Wars games", "Favourites"]),
        entry("Art Scene", "art.example.org", notes: "ANSI galleries"),
        entry("Chat", "chat.example.net", port: 2323, tags: ["favourites"]),
    ])
    #expect(dir.allTags == ["Favourites", "Trade Wars games"])
    #expect(dir.filtered(search: "", tag: nil).count == 3)
    #expect(dir.filtered(search: "galler", tag: nil).map(\.name) == ["Art Scene"])
    #expect(dir.filtered(search: "2323", tag: nil).map(\.name) == ["Chat"])
    #expect(dir.filtered(search: "TRADE", tag: nil).map(\.name) == ["Trade Wars Haven"])
    #expect(dir.filtered(search: "", tag: "Favourites").map(\.name) == ["Trade Wars Haven", "Chat"])
    #expect(dir.filtered(search: "chat", tag: "favourites").map(\.name) == ["Chat"])
}

@Test func sortByColumns() {
    var a = entry("beta", "b.example.com"); a.totalCalls = 5; a.lastCalled = fixedDate
    var b = entry("Alpha", "c.example.com"); b.totalCalls = 1
    var c = entry("gamma", "a.example.com"); c.totalCalls = 9; c.lastCalled = fixedDate.addingTimeInterval(60)
    let list = [a, b, c]
    #expect(DialingDirectory.sorted(list, by: .name, ascending: true).map(\.name) == ["Alpha", "beta", "gamma"])
    #expect(DialingDirectory.sorted(list, by: .address, ascending: true).map(\.name) == ["gamma", "beta", "Alpha"])
    #expect(DialingDirectory.sorted(list, by: .totalCalls, ascending: false).map(\.name) == ["gamma", "beta", "Alpha"])
    // Never called sorts as oldest.
    #expect(DialingDirectory.sorted(list, by: .lastCalled, ascending: true).map(\.name) == ["Alpha", "beta", "gamma"])
}

@Test func moveBeforeTarget() {
    let es = (0..<5).map { entry("E\($0)", "h\($0)") }
    var dir = DialingDirectory(entries: es)
    dir.move([es[3].id, es[0].id], before: es[2].id)
    #expect(dir.entries.map(\.name) == ["E1", "E0", "E3", "E2", "E4"])
    dir.move([es[1].id], before: nil)
    #expect(dir.entries.map(\.name) == ["E0", "E3", "E2", "E4", "E1"])
    // Moving before itself keeps the order.
    dir.move([es[2].id], before: es[2].id)
    #expect(dir.entries.map(\.name) == ["E0", "E3", "E2", "E4", "E1"])
}

@Test func duplicateGetsNewIdAndName() throws {
    var original = entry("Home", "home.example.com", user: "me")
    original.totalCalls = 4
    original.lastCalled = fixedDate
    var dir = DialingDirectory(entries: [original, entry("Other", "o")])
    let made = dir.duplicate(original.id)
    let copy = try #require(made)
    #expect(copy.id != original.id)
    #expect(copy.name == "Home copy")
    #expect(copy.host == "home.example.com" && copy.username == "me")
    #expect(copy.totalCalls == 0 && copy.lastCalled == nil)
    #expect(dir.entries.map(\.name) == ["Home", "Home copy", "Other"])
}

@Test func recordCallUpdatesHistory() {
    let e = entry("A", "a")
    var dir = DialingDirectory(entries: [e])
    dir.recordCall(e.id, at: fixedDate.addingTimeInterval(0.75))
    dir.recordCall(e.id, at: fixedDate.addingTimeInterval(10.4))
    #expect(dir.entries[0].totalCalls == 2)
    // Whole seconds, so the stored ISO 8601 date reads back equal.
    #expect(dir.entries[0].lastCalled == fixedDate.addingTimeInterval(10))
}

@Test func sharedCredentialSurvivesDelete() throws {
    let a = entry("A", "Shared.Example.com", port: 23, user: "me")
    let b = entry("B", "shared.example.com", port: 23, user: "me")
    let c = entry("C", "shared.example.com", port: 23, user: "someone")
    let dir = DialingDirectory(entries: [a, b, c])
    let key = try #require(a.credentialKey)
    #expect(key == b.credentialKey)
    #expect(dir.sharesCredential(key, excluding: a.id))
    #expect(!dir.sharesCredential(try #require(c.credentialKey), excluding: c.id))
    #expect(entry("D", "d").credentialKey == nil)
}

@Test func exportHasNoBookmarksAndRoundTrips() throws {
    var a = entry("A", "a.example.com", user: "me")
    a.captureFolderBookmark = Data([9, 9, 9])
    a.captureFolderName = "Somewhere"
    let dir = DialingDirectory(entries: [a, entry("B", "b.example.com")])
    let data = dir.exportData(ids: nil)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"format\" : \"AnsiView Dialing Directory\""))
    #expect(!text.contains("captureFolderBookmark"))
    #expect(!text.lowercased().contains("\"password\" :"))
    let back = try DialingDirectory.importEntries(from: data)
    #expect(back.map(\.name) == ["A", "B"])
    #expect(back[0].captureFolderBookmark == nil)
    // Only the chosen entries.
    #expect(try DialingDirectory.importEntries(from: dir.exportData(ids: [a.id])).map(\.name) == ["A"])
}

@Test func importSkipsDuplicatesAndRenumbers() throws {
    let a = entry("A", "a.example.com", user: "me")
    var dir = DialingDirectory(entries: [a])
    let incoming = [a, entry("B", "b.example.com")]
    let result = dir.merge(incoming)
    #expect(result.skipped == 1)
    #expect(result.added.map(\.name) == ["B"])
    #expect(result.added[0].id != incoming[1].id)
    #expect(dir.entries.map(\.name) == ["A", "B"])
}

@Test func importAcceptsPlan7Array() throws {
    let old = BBSAddressBook(entries: [entry("Old", "old.example.com")])
    #expect(try DialingDirectory.importEntries(from: old.encoded()).map(\.name) == ["Old"])
    #expect(throws: (any Error).self) { try DialingDirectory.importEntries(from: Data("nope".utf8)) }
}
