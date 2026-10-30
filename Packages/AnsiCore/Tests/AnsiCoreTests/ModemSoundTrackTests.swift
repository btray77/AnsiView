import Foundation
import Testing
@testable import AnsiCore

private func power(_ samples: ArraySlice<Float>, _ frequency: Double, rate: Double = 44_100) -> Double {
    let coefficient = 2 * cos(2 * Double.pi * frequency / rate)
    var s1 = 0.0, s2 = 0.0
    for sample in samples {
        let s0 = Double(sample) + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    }
    return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(max(1, samples.count * samples.count))
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
}

@Suite struct ModemSoundTrackTests {
    let rate = Double(ModemSoundTrack.sampleRate)

    func window(_ track: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> {
        track[Int(from * rate)..<min(track.count, Int(to * rate))]
    }

    @Test func trackLengthMatchesTimeline() {
        let track = ModemSoundTrack.samples(drawSeconds: 3, totalSeconds: 15)
        #expect(track.count == Int(15 * rate))
        // Shorter than the handshake: still the whole handshake.
        let short = ModemSoundTrack.samples(drawSeconds: 0, totalSeconds: 1)
        #expect(short.count == Int((ModemSound.handshakeSeconds * rate).rounded()))
    }

    @Test func handshakeFirst() {
        let track = ModemSoundTrack.samples(drawSeconds: 3, totalSeconds: 15)
        let answer = ModemSound.start(of: .answerTone)
        let dial = window(track, 0.1, 0.9)
        #expect(power(dial, 350) > 0.01 && power(dial, 440) > 0.01)
        let tone = window(track, answer + 0.1, answer + 1.0)
        #expect(power(tone, 2100) > 0.03)
        #expect(power(dial, 2100) < 0.001)
    }

    @Test func noiseWhileDrawingThenSilence() {
        let h = ModemSound.handshakeSeconds
        let track = ModemSoundTrack.samples(drawSeconds: 3, totalSeconds: 15)
        let drawing = rms(window(track, h + 0.1, h + 2.9))
        #expect(drawing > 0.005 && drawing < 0.06)
        #expect(window(track, h + 3.01, 15).allSatisfy { $0 == 0 })
    }

    @Test func instantHasNoNoise() {
        let h = ModemSound.handshakeSeconds
        let track = ModemSoundTrack.samples(drawSeconds: 0, totalSeconds: h + 3)
        #expect(window(track, h + 0.01, h + 3).allSatisfy { $0 == 0 })
    }

    @Test func resampledTo44100KeepsPitch() {
        let tone = (0..<22_050).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 22_050)) }
        let up = ModemSoundTrack.resample(tone, from: 22_050, to: 44_100)
        #expect(up.count == 44_100)
        #expect(power(up[...], 1000) > 0.2)
        #expect(power(up[...], 2000) < 0.001)
    }

    @Test func mixSumsClampsAndKeepsTheLonger() {
        let mixed = ModemSoundTrack.mix([0.5, 0.9, 0.1], [0.25, 0.5])
        #expect(mixed == [0.75, 1.0, 0.1])
        #expect(ModemSoundTrack.mix([], [0.2]) == [0.2])
        #expect(ModemSoundTrack.mix([-0.8], [-0.8]) == [-1])
    }

    @Test func delayPrependsSilence() {
        let delayed = ModemSoundTrack.delayed([0.5, 0.5], by: 2 / rate)
        #expect(delayed == [0, 0, 0.5, 0.5])
    }
}
