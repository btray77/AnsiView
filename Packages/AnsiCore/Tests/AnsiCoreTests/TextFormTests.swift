import Foundation
import Testing
@testable import AnsiCore

private func screenText(_ screen: AnsiScreen) -> [String] {
    screen.rows.map { String($0.map { Character(CP437.unicode[Int($0.code)]) }) }
}

private func sampleForm() -> TextForm {
    TextForm(title: "Edit", fields: [
        .text("name", section: "Connection", label: "Name", hint: "A label for the list.", value: "Home", maxLength: 8),
        .number("port", section: "Connection", label: "Port", hint: "The port.", value: 23, range: 1...65535),
        .choice("mode", section: "Connection", label: "Protocol", hint: "How to talk.", options: ["Telnet", "Raw TCP"], index: 0),
        .secret("password", section: "Login", label: "Password", hint: "Kept in the Keychain.", value: "hunter2"),
        .toggle("show", section: "Login", label: "Show password", hint: "Shows it.", isOn: false, revealsSecrets: true),
        .action("reset", section: "Login", label: "Reset script", hint: "Puts back the default.", caption: "Reset"),
    ], info: "Last called: Never")
}

@Test func formNavigationStopsAtEnds() {
    var f = sampleForm()
    #expect(f.selected == 0)
    #expect(f.handle(.up) == FormEvent.none)
    #expect(f.selected == 0)
    _ = f.handle(.down); _ = f.handle(.tab)
    #expect(f.selected == 2)
    _ = f.handle(.backTab)
    #expect(f.selected == 1)
    _ = f.handle(.enter)
    #expect(f.selected == 2)
    for _ in 0..<10 { _ = f.handle(.down) }
    #expect(f.selected == 5)
    _ = f.handle(.pageUp)
    #expect(f.selected == 0)
    _ = f.handle(.pageDown)
    #expect(f.selected == 5)
}

@Test func formTextEditing() {
    var f = sampleForm()
    #expect(f.caret == 4)
    #expect(f.handle(.character("s")) == .changed("name"))
    #expect(f.fields[0].text == "Homes")
    _ = f.handle(.home)
    _ = f.handle(.character("M"))
    #expect(f.fields[0].text == "MHomes")
    _ = f.handle(.right); _ = f.handle(.forwardDelete)
    #expect(f.fields[0].text == "MHmes")
    _ = f.handle(.end); _ = f.handle(.backspace)
    #expect(f.fields[0].text == "MHme")
    // maxLength 8.
    for c in "abcdefgh" { _ = f.handle(.character(c)) }
    #expect(f.fields[0].text == "MHmeabcd")
    // Control characters are not typed.
    _ = f.handle(.backspace)
    #expect(f.handle(.character("\u{7}")) == FormEvent.none)
}

@Test func formChoicesCycle() {
    var f = sampleForm()
    f.select(id: "mode")
    #expect(f.handle(.right) == .changed("mode"))
    #expect(f.fields[2].index == 1)
    _ = f.handle(.right)
    #expect(f.fields[2].index == 0)
    _ = f.handle(.left)
    #expect(f.fields[2].index == 1)
    _ = f.handle(.character(" "))
    #expect(f.fields[2].index == 0)
    #expect(f.fields[2].choiceValue == "Telnet")
}

@Test func formTogglesAndActions() {
    var f = sampleForm()
    f.select(id: "show")
    #expect(f.handle(.right) == .changed("show"))
    #expect(f.fields[4].isOn)
    _ = f.handle(.character(" "))
    #expect(!f.fields[4].isOn)
    f.select(id: "reset")
    #expect(f.handle(.enter) == .activated("reset"))
    #expect(f.handle(.escape) == .done)
}

@Test func formNumbers() {
    var f = sampleForm()
    f.select(id: "port")
    _ = f.handle(.right)
    #expect(f.fields[1].number == 24)
    _ = f.handle(.backspace); _ = f.handle(.backspace)
    #expect(f.handle(.character("x")) == FormEvent.none)
    for c in "999999" { _ = f.handle(.character(c)) }
    // Leaving the field clamps it.
    _ = f.handle(.down)
    #expect(f.fields[1].number == 65535)
    #expect(f.fields[1].text == "65535")
    f.select(id: "port")
    for _ in 0..<5 { _ = f.handle(.backspace) }
    _ = f.handle(.up)
    #expect(f.fields[1].number == 1)
}

@Test func formScreenLooksRetro() throws {
    var f = sampleForm()
    f.select(id: "port")
    let rendered = f.screen(columns: 80, rows: 25)
    let text = screenText(rendered.screen)
    #expect(rendered.screen.rows.count == 25 && rendered.screen.rows.allSatisfy { $0.count == 80 })
    #expect(rendered.screen.rows[0][0].code == 0xC9)
    #expect(rendered.screen.rows[0][0].fg == Palette.vga[9])
    #expect(text[0].contains("Edit"))
    // Section headings in yellow.
    let headingRow = try #require(text.firstIndex { $0.contains("Connection") })
    let column = text[headingRow].range(of: "Connection")!.lowerBound.utf16Offset(in: text[headingRow])
    #expect(rendered.screen.rows[headingRow][column].fg == Palette.vga[14])
    // The selected field's hint is shown, and its row maps back to it.
    #expect(text.contains { $0.contains("The port.") })
    let portRow = try #require(rendered.fieldAtRow.first { $0.value == 1 }?.key)
    #expect(text[portRow].contains("Port"))
    // The selected value is highlighted; others are grey on black.
    #expect(rendered.screen.rows[portRow].contains { $0.bg == Palette.vga[3] })
    let nameRow = try #require(rendered.fieldAtRow.first { $0.value == 0 }?.key)
    #expect(!rendered.screen.rows[nameRow].contains { $0.bg == Palette.vga[3] })
    #expect(text.contains { $0.contains("Last called: Never") })
    #expect(text[24].contains("Esc"))
}

@Test func formSecretsMaskedUntilShown() {
    var f = sampleForm()
    var text = screenText(f.screen(columns: 80, rows: 25).screen).joined()
    #expect(!text.contains("hunter2"))
    #expect(text.contains("*******"))
    f.select(id: "show")
    _ = f.handle(.right)
    text = screenText(f.screen(columns: 80, rows: 25).screen).joined()
    #expect(text.contains("hunter2"))
}

@Test func formScrollsToSelection() {
    let fields = (0..<40).map { FormField.text("f\($0)", section: $0 < 20 ? "One" : "Two", label: "Field \($0)", hint: "Hint \($0).", value: "") }
    var f = TextForm(title: "Many", fields: fields, info: "")
    f.select(id: "f39")
    let rendered = f.screen(columns: 80, rows: 25)
    #expect(rendered.fieldAtRow.values.contains(39))
    #expect(screenText(rendered.screen).contains { $0.contains("Field 39") })
    #expect(!rendered.fieldAtRow.values.contains(0))
}

@Test func formClickSelects() throws {
    var f = sampleForm()
    let rendered = f.screen(columns: 80, rows: 25)
    let row = try #require(rendered.fieldAtRow.first { $0.value == 2 }?.key)
    // A first click selects; a click on the selected choice cycles it.
    #expect(f.click(row: row, map: rendered.fieldAtRow) == FormEvent.none)
    #expect(f.selected == 2)
    #expect(f.click(row: row, map: rendered.fieldAtRow) == .changed("mode"))
    #expect(f.fields[2].index == 1)
    #expect(f.click(row: 0, map: rendered.fieldAtRow) == FormEvent.none)
}
