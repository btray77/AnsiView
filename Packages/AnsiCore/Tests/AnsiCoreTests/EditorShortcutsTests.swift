import Foundation
import Testing
@testable import AnsiCore

@Suite struct EditorShortcutsTests {
    @Test func defaultsHaveNoConflictsAndEveryActionHasTextAndKey() {
        let shortcuts = EditorShortcuts()
        #expect(shortcuts.conflicts.isEmpty)
        for action in EditorAction.allCases {
            #expect(!action.title.isEmpty && !action.hint.isEmpty)
            #expect(shortcuts.combo(for: action) == action.defaultCombo)
            #expect(shortcuts.action(for: action.defaultCombo) == action)
        }
        #expect(EditorAction.swapColours.defaultCombo == KeyCombo("x"))
        #expect(EditorAction.toggleInsert.defaultCombo == KeyCombo("insert"))
        #expect(EditorAction.toolLine.defaultCombo == KeyCombo("l", control: true))
    }

    @Test func overridesAndConflicts() {
        var shortcuts = EditorShortcuts()
        shortcuts.set(KeyCombo("l", control: true), for: .toolBox)
        #expect(shortcuts.combo(for: .toolBox) == KeyCombo("l", control: true))
        #expect(Set(shortcuts.conflicts(for: .toolBox)) == [.toolLine])
        #expect(shortcuts.conflicts[KeyCombo("l", control: true)].map(Set.init) == [.toolLine, .toolBox])
        shortcuts.reset(.toolBox)
        #expect(shortcuts.conflicts.isEmpty && shortcuts.combo(for: .toolBox) == EditorAction.toolBox.defaultCombo)
        shortcuts.set(KeyCombo("q", option: true), for: .swapColours)
        shortcuts.resetAll()
        #expect(shortcuts == EditorShortcuts())
    }

    @Test func storageRoundTrip() {
        var shortcuts = EditorShortcuts()
        shortcuts.set(KeyCombo("n", control: true, option: true, shift: true), for: .insertLine)
        shortcuts.set(KeyCombo("f5"), for: .characterPicker)
        let plist = shortcuts.plist
        #expect(plist["insertLine"] == "ctrl+option+shift+n")
        #expect(EditorShortcuts(plist: plist) == shortcuts)
        // Unknown actions and unreadable combos are ignored.
        #expect(EditorShortcuts(plist: ["nope": "ctrl+a", "insertLine": "+++"]) == EditorShortcuts())
    }

    @Test func displayStrings() {
        #expect(KeyCombo("n", control: true, shift: true).display == "⌃⇧N")
        #expect(KeyCombo("insert").display == "Insert")
        #expect(KeyCombo("x").display == "X")
        #expect(KeyCombo("left", option: true).display == "⌥←")
        #expect(KeyCombo("'", control: true).display == "⌃'")
        #expect(KeyCombo("f3", command: true).display == "⌘F3")
    }

    @Test func keyNamesForFunctionKeys() {
        #expect(KeyCombo.keyName(scalar: 0xF727) == "insert")
        #expect(KeyCombo.keyName(scalar: 0xF702) == "left")
        #expect(KeyCombo.keyName(scalar: 0xF706) == "f3")
        #expect(KeyCombo.keyName(scalar: 0x4E) == "n")
        #expect(KeyCombo.keyName(scalar: 0x0D) == "return")
        #expect(KeyCombo("x").isPlain && !KeyCombo("x", control: true).isPlain && !KeyCombo("insert").isPlain)
    }
}
