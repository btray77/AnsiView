import Foundation
import Testing
@testable import AnsiCore

private let fonts = ["IBM VGA", "IBM EGA", "Topaz"]
private let speeds = [300, 2400, 9600, 0]

private func richEntry() -> BBSEntry {
    var e = BBSEntry(name: "Home", host: "home.example.com", port: 2323)
    e.username = "sysop"
    e.tags = ["Favourites", "Trade Wars games"]
    e.notes = "Weekend tournament"
    e.mode = .raw
    e.terminalType = "VT100"
    e.columns = 132
    e.rows = 50
    e.fontName = "IBM EGA"
    e.encoding = .utf8
    e.iceColors = true
    e.baud = 9600
    e.backspaceSendsDelete = true
    e.modemSound = .off
    e.autoLogin = false
    e.loginScript.append(LoginStep(expect: "continue?", send: .text, text: "Y\\r", timeout: 12))
    e.busyText = "full up"
    e.captureOnConnect = true
    e.captureFolderName = "Captures"
    e.macros[0] = "/who\\r"
    e.macros[9] = "bye"
    return e
}

@Test func entryFormRoundTrip() {
    let e = richEntry()
    let form = EntryForm.make(entry: e, password: "s3cret", fonts: fonts, speeds: speeds)
    let back = EntryForm.apply(form, to: e)
    #expect(back.entry == e)
    #expect(back.password == "s3cret")
    let plain = BBSEntry(name: "P", host: "p.example.com")
    let plainBack = EntryForm.apply(EntryForm.make(entry: plain, password: "", fonts: fonts, speeds: speeds), to: plain)
    #expect(plainBack.entry == plain)
    #expect(plainBack.password.isEmpty)
}

@Test func everyEntryFieldHasAHint() {
    let form = EntryForm.make(entry: richEntry(), password: "", fonts: fonts, speeds: speeds)
    #expect(form.fields.count > 30)
    #expect(Set(form.fields.map(\.id)).count == form.fields.count)
    for field in form.fields {
        #expect(field.hint.count > 20, "\(field.id)")
        #expect(!field.hint.contains("\u{2014}"), "\(field.id)")
    }
    // The name hint says it is only a label.
    #expect(form.field("name")?.hint.lowercased().contains("label") == true)
    #expect(form.fields.map(\.section).contains("Connection"))
    #expect(form.fields.map(\.section).contains("Login"))
}

@Test func entryFormEditsApply() {
    let e = BBSEntry(name: "Old", host: "old.example.com")
    var form = EntryForm.make(entry: e, password: "", fonts: fonts, speeds: speeds)
    form.select(id: "name")
    for _ in 0..<3 { _ = form.handle(.backspace) }
    for c in "New" { _ = form.handle(.character(c)) }
    form.select(id: "mode")
    _ = form.handle(.right)
    form.select(id: "tags")
    for c in "Fun, , Games ," { _ = form.handle(.character(c)) }
    form.select(id: "password")
    for c in "pw" { _ = form.handle(.character(c)) }
    form.select(id: "font")
    _ = form.handle(.right)
    form.select(id: "baud")
    _ = form.handle(.left)
    let back = EntryForm.apply(form, to: e)
    #expect(back.entry.name == "New")
    #expect(back.entry.mode == .raw)
    #expect(back.entry.tags == ["Fun", "Games"])
    #expect(back.entry.fontName == "IBM EGA")
    #expect(back.entry.baud == 9600)
    #expect(back.password == "pw")
}

@Test func entryFormScriptActions() {
    var e = BBSEntry(name: "S", host: "s.example.com")
    e.loginScript = EntryForm.perform("addStep", on: e).loginScript
    #expect(e.loginScript.count == 3)
    #expect(EntryForm.make(entry: e, password: "", fonts: fonts, speeds: speeds).field("step.2.expect") != nil)
    e.loginScript = EntryForm.perform("removeStep", on: e).loginScript
    e.loginScript = EntryForm.perform("removeStep", on: e).loginScript
    #expect(e.loginScript.count == 1)
    e.loginScript = EntryForm.perform("resetScript", on: e).loginScript
    #expect(e.loginScript == LoginScript.defaultSteps)
    e.captureFolderName = "X"
    e.captureFolderBookmark = Data([1])
    let cleared = EntryForm.perform("clearFolder", on: e)
    #expect(cleared.captureFolderBookmark == nil && cleared.captureFolderName == nil)
}

@Test func entryFormInfoLine() {
    var e = BBSEntry(name: "S", host: "s")
    #expect(EntryForm.info(for: e).contains("Never"))
    e.totalCalls = 12
    e.lastCalled = Date(timeIntervalSince1970: 1_790_000_000)
    let info = EntryForm.info(for: e, timeZone: TimeZone(identifier: "UTC")!)
    #expect(info.contains("12"))
    #expect(info.contains("2026-09-21"))
}

@Test func terminalTypeOrderAndIce() {
    var e = BBSEntry(name: "T", host: "t")
    #expect(e.terminalType == "ANSI" && !e.iceColors)
    #expect(e.terminalTypes == ["ANSI", "ANSI-BBS", "VT100"])
    e.terminalType = "VT100"
    #expect(e.terminalTypes == ["VT100", "ANSI", "ANSI-BBS"])
    e.terminalType = "XTERM"
    #expect(e.terminalTypes == ["XTERM", "ANSI", "ANSI-BBS", "VT100"])
}

@Test func emulatorIceColours() {
    var normal = TerminalEmulator(columns: 10, rows: 2)
    normal.feed(Array("\u{1B}[5;44mX".utf8))
    #expect(normal.grid[0][0].blink)
    #expect(normal.grid[0][0].bg == Palette.vga[1])
    var ice = TerminalEmulator(columns: 10, rows: 2)
    ice.iceColors = true
    ice.feed(Array("\u{1B}[5;44mX".utf8))
    #expect(!ice.grid[0][0].blink)
    #expect(ice.grid[0][0].bg == Palette.vga[9])
}
