import Foundation
import Testing
@testable import AnsiCore

@Test func settingsFormRoundTrip() {
    var d = DialingDirectory()
    d.globalMacros[2] = "/q\\r"
    d.redialAttempts = 7
    d.redialDelay = 45
    d.showAtLaunch = true
    var form = EntryForm.settings(d)
    #expect(EntryForm.applySettings(form, to: d) == d)
    #expect(form.fields.allSatisfy { $0.hint.count > 20 })
    form.select(id: "showAtLaunch")
    _ = form.handle(.right)
    form.select(id: "macro.0")
    for c in "hi" { _ = form.handle(.character(c)) }
    let back = EntryForm.applySettings(form, to: d)
    #expect(!back.showAtLaunch && back.globalMacros[0] == "hi")
}
