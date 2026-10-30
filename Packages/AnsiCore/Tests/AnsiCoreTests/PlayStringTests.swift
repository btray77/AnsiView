import Foundation
import Testing
@testable import AnsiCore

@Suite struct PlayStringTests {
    private func notes(_ text: String, dialect: PlayDialect = .gwbasic) -> [TimedNote] {
        let parsed = PlayString.parse(text, dialect: dialect)
        return PlayString.schedule(parsed.items, dialect: dialect)
    }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    @Test func quarterNoteAtT120LastsHalfSecond() {
        let result = notes("T120 L4 O4 C")
        #expect(result.count == 1)
        #expect(close(result[0].duration, 0.5))
        #expect(close(result[0].sounding, 0.4375))
        #expect(close(result[0].frequency, 1046.50, 0.01))
        #expect(result[0].semitone == 48)
    }

    @Test func frequencyTable() {
        #expect(close(PlayString.frequency(semitone: 0), 65.406, 0.001))
        #expect(close(PlayString.frequency(semitone: 81), 7040))
        #expect(close(PlayString.frequency(semitone: 33), 440))
        #expect(close(PlayString.frequency(semitone: 57), 1760))
        #expect(close(PlayString.frequency(semitone: 72), 4186.009, 0.001))
        #expect(PlayString.noteName(48) == "O4 C")
        #expect(PlayString.noteName(49) == "O4 C#")
    }

    @Test func octaveAndShifts() {
        #expect(notes("O2 C > C < < C").map(\.semitone) == [24, 36, 12])
        #expect(notes("O0 < C").map(\.semitone) == [0])
        #expect(notes("O6 > C").map(\.semitone) == [72])
    }

    @Test func sharpsFlatsAndArithmetic() {
        #expect(notes("C# D+ E- C-").map(\.semitone) == [49, 51, 51, 47])
        #expect(notes("B# E# F- C##").map(\.semitone) == [60, 53, 52, 50])
        // Shifted outside the 7 octaves: silence for the note's length.
        let low = notes("O0 C-")
        #expect(low.count == 1)
        #expect(low[0].semitone == nil)
        #expect(close(low[0].duration, 0.5))
    }

    @Test func lengthsDotsAndSuffixes() {
        #expect(notes("L8 C C4 C. C..").map(\.duration).map { ($0 * 10000).rounded() / 10000 } == [0.25, 0.5, 0.375, 0.5625])
        #expect(close(notes("L8 C..", dialect: .syncterm)[0].duration, 0.375))
        // Length suffix then dot.
        #expect(close(notes("C2.")[0].duration, 1.5))
    }

    @Test func articulations() {
        #expect(close(notes("MS C")[0].sounding, 0.375))
        #expect(close(notes("ML C")[0].sounding, 0.5))
        #expect(close(notes("ML MN C")[0].sounding, 0.4375))
        // Articulation persists.
        #expect(notes("MS C D").map(\.sounding).allSatisfy { close($0, 0.375) })
    }

    @Test func numberNotes() {
        let result = notes("N1 N37 N0 N84 N85")
        #expect(result.map(\.semitone) == [0, 36, nil, 83, nil])
        #expect(result.allSatisfy { close($0.duration, 0.5) })
        // N uses L and takes no length suffix of its own beyond the next number.
        #expect(close(notes("L8 N37")[0].duration, 0.25))
    }

    @Test func pausesAndRests() {
        let pause = notes("P8")
        #expect(pause.count == 1)
        #expect(pause[0].semitone == nil)
        #expect(pause[0].frequency == 0)
        #expect(close(pause[0].duration, 0.25))
        #expect(close(pause[0].sounding, 0))
        #expect(close(notes("L2 P")[0].duration, 1.0))
        #expect(notes("P0").isEmpty)
        // Starts follow one another.
        let seq = notes("C P4 D")
        #expect(seq.map(\.start).map { ($0 * 1000).rounded() / 1000 } == [0, 0.5, 1.0])
    }

    @Test func clampsTempoOctaveLength() {
        #expect(PlayString.parse("T10").endState.tempo == 32)
        #expect(PlayString.parse("T999").endState.tempo == 255)
        #expect(PlayString.parse("O9").endState.octave == 6)
        #expect(PlayString.parse("L0").endState.length == 1)
        #expect(PlayString.parse("L99").endState.length == 64)
        #expect(close(notes("C99")[0].duration, 240.0 / (120 * 64)))
        // A bare T, O or L without digits changes nothing.
        #expect(PlayString.parse("T O L").endState == PlayState())
    }

    @Test func backgroundFlag() {
        let result = notes("MB C MF D")
        #expect(result.map(\.background) == [true, false])
        #expect(PlayString.parse("MB").endState.background)
    }

    @Test func lowercaseAndSpaces() {
        #expect(notes("t120 o3 l8 c d e").map(\.semitone) == [36, 38, 40])
        #expect(notes("o3l8cde").map(\.semitone) == [36, 38, 40])
    }

    @Test func unknownCharactersWarn() {
        let parsed = PlayString.parse("C Z D")
        #expect(parsed.items.count == 2)
        #expect(parsed.warnings.count == 1)
    }

    @Test func stateCarriesOver() {
        let first = PlayString.parse("T200 O2 L8 MS")
        let second = PlayString.parse("C", from: first.endState)
        let timed = PlayString.schedule(second.items, from: first.endState)
        #expect(timed[0].semitone == 24)
        #expect(close(timed[0].duration, 240.0 / (200 * 8)))
        #expect(close(timed[0].sounding, 240.0 / (200 * 8) * 0.75))
    }

    @Test func serializerRoundTrip() {
        let samples = [
            "T120 L4 O4 C", "T180 O3 L8 E E F G G F E D C C D E E. D16 D4",
            "MB T90 O2 L16 C D E F G A B > C", "MS N1 N37 N0 P8 C#4. D-2", "ML T255 O6 B L64 C D", "O0 C- O6 B#",
        ]
        for text in samples {
            let first = PlayString.parse(text)
            let canonical = PlayString.serialize(first.items)
            let second = PlayString.parse(canonical)
            #expect(second.items == first.items, "\(text) -> \(canonical)")
            #expect(PlayString.serialize(second.items) == canonical)
            #expect(second.warnings.isEmpty)
        }
    }

    @Test func serializerStartsFromState() {
        var state = PlayState()
        state.tempo = 150
        state.octave = 2
        let items: [PlayItem] = [.note(semitone: 24, length: 4, dots: 0)]
        // Already at T150 O2 L4: nothing to set.
        #expect(PlayString.serialize(items, from: state) == "C")
        #expect(PlayString.serialize(items) == "O2 C")
    }

    @Test func fuzzNeverCrashesAndIsBounded() {
        var generator = SeededGenerator(seed: 0x5EED)
        let alphabet = Array("aAbBcCdDeEfFgGlLmMnNoOpPsStT0123456789.-+#<> ZX=;!\u{1B}\u{0E}")
        for _ in 0..<2000 {
            let length = Int.random(in: 0...300, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            let parsed = PlayString.parse(text)
            #expect(parsed.items.count <= text.count)
            for note in PlayString.schedule(parsed.items) {
                #expect(note.duration.isFinite && note.duration > 0 && note.duration <= 60)
                #expect(note.sounding >= 0 && note.sounding <= note.duration)
            }
        }
        // Many dots stay bounded.
        #expect(notes("T32 L1 C" + String(repeating: ".", count: 200))[0].duration <= 60)
    }
}

/// A small deterministic generator (SplitMix64) so fuzz tests repeat exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
