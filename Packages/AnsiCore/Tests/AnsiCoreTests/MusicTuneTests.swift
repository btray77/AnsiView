import Foundation
import Testing
@testable import AnsiCore

@Suite struct MusicTuneTests {
    @Test func addNotePastEndFillsRests() {
        var tune = MusicTune()
        let index = tune.addNote(semitone: 48, at: 0.5, length: 4)
        #expect(tune.play == "P2 C")
        #expect(tune.placed[index].semitone == 48)
        #expect(tune.placed[index].position == 0.5)
        // 3/8 gap: P4 P8.
        var gap = MusicTune(play: "C")
        _ = gap.addNote(semitone: 50, at: 0.625, length: 8)
        #expect(gap.play == "C P4 P8 D8")
    }

    @Test func addInsideRestSplits() {
        var tune = MusicTune(play: "P1 C")
        _ = tune.addNote(semitone: 52, at: 0.25, length: 4)
        #expect(tune.play == "P4 E P2 C")
        #expect(tune.placed.last?.position == 1.0)
    }

    @Test func clickOnNoteChangesPitch() {
        var tune = MusicTune(play: "C D E")
        let index = tune.addNote(semitone: 55, at: 0.3, length: 4)
        #expect(tune.play == "C G E")
        #expect(tune.placed.firstIndex { $0.index == index } == 1)
        tune.setPitch(index: index, semitone: 53)
        #expect(tune.play == "C F E")
    }

    @Test func setLengthSnaps() {
        #expect(MusicTune.nearestLength(0.37) == (length: 4, dots: 1))
        #expect(MusicTune.nearestLength(0.25) == (length: 4, dots: 0))
        #expect(MusicTune.nearestLength(0.34) == (length: 3, dots: 0))
        #expect(MusicTune.nearestLength(100) == (length: 1, dots: 2))
        #expect(MusicTune.nearestLength(0) == (length: 64, dots: 0))
        var tune = MusicTune(play: "C D")
        tune.setLength(index: tune.placed[0].index, wholeNotes: 0.5)
        #expect(tune.play == "C2 D")
    }

    @Test func deleteMakesRestAndTrimsTail() {
        var tune = MusicTune(play: "C D E")
        tune.delete(index: tune.placed[1].index)
        #expect(tune.play == "C P4 E")
        tune.delete(index: tune.placed[2].index)
        #expect(tune.play == "C")
    }

    @Test func textSync() {
        var tune = MusicTune(play: "t150 o2 l8 c d e")
        #expect(tune.play == "T150 O2 L8 C D E")
        #expect(MusicTune(play: tune.play) == tune)
        tune.append(semitone: 60, length: 8, dots: 0)
        #expect(tune.play.hasSuffix("O5 C"))
        #expect(MusicTune(play: tune.play) == tune)
    }

    @Test func tempoArticulationAndMode() {
        var tune = MusicTune(play: "C D")
        tune.tempo = 90
        tune.articulation = .staccato
        tune.background = true
        #expect(tune.play == "T90 MS MB C D")
        #expect(tune.tempo == 90)
        tune.tempo = 120
        tune.articulation = .normal
        tune.background = false
        #expect(tune.play == "C D")
        // Imported state becomes part of the tune.
        var state = PlayState()
        state.tempo = 200
        #expect(MusicTune(items: [.note(semitone: 48, length: 4, dots: 0)], startingFrom: state).play == "T200 C")
    }

    @Test func insertSnippet() {
        var tune = MusicTune(play: "C D")
        let snippet = MusicTune(play: "T200 E F")
        tune.insert(snippet, at: 1)
        #expect(tune.play == "C T200 E F T120 D")
        // Duration of D is back at T120.
        #expect(tune.notes.last?.duration == 0.5)
        var end = MusicTune(play: "C")
        end.insert(MusicTune(play: "D"), at: 99)
        #expect(end.play == "C D")
    }

    @Test func keyboardMap() {
        #expect(MusicKeyboard.semitoneOffset(for: "a") == 0)
        #expect(MusicKeyboard.semitoneOffset(for: "w") == 1)
        #expect(MusicKeyboard.semitoneOffset(for: "j") == 11)
        #expect(MusicKeyboard.semitoneOffset(for: "k") == 12)
        #expect(MusicKeyboard.semitoneOffset(for: "A") == 0)
        #expect(MusicKeyboard.semitoneOffset(for: "q") == nil)
        #expect(MusicKeyboard.length(for: "1") == 1)
        #expect(MusicKeyboard.length(for: "4") == 8)
        #expect(MusicKeyboard.length(for: "7") == 64)
        #expect(MusicKeyboard.length(for: "8") == nil)
    }

    @Test func libraryCodableAndBadData() {
        var library = MusicLibrary()
        let first = library.add(name: "Fanfare", play: "T200 C E G")
        _ = library.add(name: "Bass", play: "O1 C")
        library.remove(id: first.id)
        let decoded = MusicLibrary.decode(library.encoded())
        #expect(decoded == library)
        #expect(decoded.snippets.map(\.name) == ["Bass"])
        #expect(MusicLibrary.decode(Data("not json".utf8)).snippets.isEmpty)
        #expect(String(decoding: library.encoded(), as: UTF8.self).contains("\"version\":1"))
    }

    @Test func demosParseCleanly() {
        #expect(MusicDemos.all.count >= 5)
        for demo in MusicDemos.all {
            let parsed = PlayString.parse(demo.play)
            #expect(parsed.warnings.isEmpty, "\(demo.title): \(parsed.warnings)")
            let seconds = PlayString.schedule(parsed.items).last?.end ?? 0
            #expect(seconds >= 1 && seconds <= 120, "\(demo.title) \(seconds)")
            #expect(MusicTune(play: demo.play).notes == PlayString.schedule(parsed.items))
            #expect(!demo.credit.isEmpty)
        }
    }
}
