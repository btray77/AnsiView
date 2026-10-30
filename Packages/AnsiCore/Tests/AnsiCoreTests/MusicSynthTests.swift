import Foundation
import Testing
@testable import AnsiCore

@Suite struct MusicSynthTests {
    private func timed(_ play: String) -> [TimedNote] { PlayString.schedule(PlayString.parse(play).items) }

    private func crossings(_ samples: ArraySlice<Float>) -> Int {
        var count = 0
        var previous = samples.first.map { $0 >= 0 } ?? true
        for value in samples.dropFirst() where value != 0 {
            let positive = value > 0
            if positive != previous { count += 1 }
            previous = positive
        }
        return count
    }

    @Test func quarterNoteSampleCount() {
        let samples = MusicSynth().render(timed("T120 L4 O4 C"))
        #expect(samples.count == 22050)
        #expect(samples[0..<19294].allSatisfy { $0 != 0 })
        #expect(samples[19294...].allSatisfy { $0 == 0 })
    }

    @Test func squareFrequencyByZeroCrossings() {
        let samples = MusicSynth().render(timed("O2 A"))
        let measured = Double(crossings(samples[0..<19294])) / 2 / (19294.0 / 44100)
        #expect(abs(measured - 440) < 3)
        let high = MusicSynth().render(timed("O4 C"))
        let measuredHigh = Double(crossings(high[0..<19294])) / 2 / (19294.0 / 44100)
        #expect(abs(measuredHigh - 1046.5) < 3)
    }

    @Test func softToneIsQuieterAtEdgesAndSameLength() {
        let square = MusicSynth().render(timed("C"))
        let soft = MusicSynth(waveform: .soft).render(timed("C"))
        #expect(soft.count == square.count)
        #expect(abs(soft[1]) < 0.05)
        #expect(soft.map(abs).max()! <= 0.3)
        // Still the same pitch.
        let measured = Double(crossings(soft[0..<19294])) / 2 / (19294.0 / 44100)
        #expect(abs(measured - 1046.5) < 5)
    }

    @Test func deterministic() {
        let notes = timed("T200 L16 O3 C D E F G A B > C")
        #expect(MusicSynth().render(notes) == MusicSynth().render(notes))
        #expect(MusicSynth(waveform: .soft).render(notes) == MusicSynth(waveform: .soft).render(notes))
    }

    @Test func restIsSilent() {
        let samples = MusicSynth().render(timed("P4 C"))
        #expect(samples[0..<22050].allSatisfy { $0 == 0 })
        #expect(samples[22050] != 0)
    }

    @Test func cumulativeTimingNoDrift() {
        let notes = timed("T255 L64 " + String(repeating: "C ", count: 64))
        let total = notes.map(\.duration).reduce(0, +)
        #expect(MusicSynth().render(notes).count == Int((total * 44100).rounded()))
    }

    @Test func renderIsCapped() {
        var synth = MusicSynth()
        synth.maxSeconds = 1
        #expect(synth.render(timed("T32 L1 C C")).count == 44100)
        #expect(MusicSynth().render([]).isEmpty)
    }

    @Test func wavHeader() {
        let data = [UInt8](WAVFile.data([0, 0.5, -2, 2]))
        #expect(data.count == 44 + 8)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8))
        #expect(Array(data[8..<16]) == Array("WAVEfmt ".utf8))
        func u32(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
        #expect(u32(4) == 36 + 8)
        #expect(u32(16) == 16)
        #expect(u16(20) == 1)
        #expect(u16(22) == 1)
        #expect(u32(24) == 44100)
        #expect(u32(28) == 88200)
        #expect(u16(32) == 2)
        #expect(u16(34) == 16)
        #expect(Array(data[36..<40]) == Array("data".utf8))
        #expect(u32(40) == 8)
        #expect(Int16(bitPattern: UInt16(u16(44))) == 0)
        #expect(Int16(bitPattern: UInt16(u16(46))) == 16384)
        #expect(Int16(bitPattern: UInt16(u16(48))) == -32767)
        #expect(Int16(bitPattern: UInt16(u16(50))) == 32767)
    }

    @Test func midiStructure() {
        let data = [UInt8](MIDIFile.data(timed("O3 C")))
        #expect(Array(data[0..<14]) == Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0])
        #expect(Array(data[14..<18]) == Array("MTrk".utf8))
        let length = Int(data[18]) << 24 | Int(data[19]) << 16 | Int(data[20]) << 8 | Int(data[21])
        #expect(length == data.count - 22)
        let track = Array(data[22...])
        #expect(Array(track[0..<7]) == [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
        #expect(Array(track[7..<10]) == [0x00, 0xC0, 80])
        #expect(Array(track[10..<14]) == [0x00, 0x90, 72, 100])
        // Note off after 0.4375 s = 420 ticks (VLQ 0x83 0x24).
        #expect(Array(track[14..<18]) == [0x83, 0x24, 0x80, 72])
        #expect(Array(track.suffix(3)) == [0xFF, 0x2F, 0x00])
    }

    @Test func midiRestsBecomeGaps() {
        let data = [UInt8](MIDIFile.data(timed("P4 O3 C")))
        let track = Array(data[22...])
        // First note on comes after the 0.5 s rest = 480 ticks (VLQ 0x83 0x60).
        #expect(Array(track[10..<15]) == [0x83, 0x60, 0x90, 72, 100])
    }
}
