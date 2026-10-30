import Foundation
import Testing
@testable import AnsiCore

/// The dialing directory entry's ANSI music mode (terminal playback).
@Suite struct MusicEntryTests {
    @Test func entryMusicModeDefaultsAndDecodes() throws {
        let entry = BBSEntry(name: "A", host: "a.example.com")
        #expect(entry.musicMode == .bananaCom)
        // An entry saved before the field existed loads with the SyncTERM default.
        let old = Data(#"{"name":"Old","host":"old.example.com"}"#.utf8)
        #expect(try JSONDecoder().decode(BBSEntry.self, from: old).musicMode == .bananaCom)
        var all = entry
        all.musicMode = .all
        let back = try JSONDecoder().decode(BBSEntry.self, from: JSONEncoder().encode(all))
        #expect(back.musicMode == .all)
        let bad = Data(#"{"name":"Bad","host":"b.example.com","musicMode":42}"#.utf8)
        #expect(try JSONDecoder().decode(BBSEntry.self, from: bad).musicMode == .bananaCom)
    }

    @Test func entryFormHasMusicModeChoice() throws {
        var entry = BBSEntry(name: "A", host: "a.example.com")
        entry.musicMode = .pipe
        var form = EntryForm.make(entry: entry, password: "", fonts: ["IBM VGA"], speeds: [0])
        let field = try #require(form.field("musicMode"))
        #expect(field.section == "Terminal")
        #expect(field.index == 1)
        for code in ["ESC[M", "ESC[N", "ESC[|", "MF", "MB", "BANSI"] {
            #expect(field.hint.contains(code))
        }
        // The editor shows two hint lines on an 80 column screen.
        #expect(RetroCanvas.wrap(field.hint, width: 74).count <= 2)
        if case .choice(let options) = field.kind {
            #expect(options == MusicMode.allCases.map(\.entryLabel))
            #expect(options.count == 4)
        } else {
            Issue.record("musicMode is not a choice")
        }
        let index = try #require(form.fields.firstIndex { $0.id == "musicMode" })
        form.fields[index].index = 3
        #expect(EntryForm.apply(form, to: entry).entry.musicMode == .all)
        // Unchanged forms round trip.
        #expect(EntryForm.apply(EntryForm.make(entry: entry, password: "", fonts: ["IBM VGA"], speeds: [0]), to: entry).entry == entry)
    }
}
