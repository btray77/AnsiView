import Testing
@testable import AnsiCore

private func slice(_ samples: [Float], from start: Double, seconds: Double) -> ArraySlice<Float> {
    let a = Int(start * ModemSound.sampleRate), b = Int((start + seconds) * ModemSound.sampleRate)
    return samples[a..<min(b, samples.count)]
}

/// True when every frequency in `present` is at least 10 times stronger than every one in `absent`.
private func dominates(_ s: ArraySlice<Float>, _ present: [Double], over absent: [Double]) -> Bool {
    let weakest = present.map { ModemSound.goertzel(s, frequency: $0) }.min()!
    let strongest = absent.map { ModemSound.goertzel(s, frequency: $0) }.max()!
    return weakest > strongest * 10
}

@Test func handshakeLengthMatches() {
    let samples = ModemSound.handshake()
    #expect(samples.count == Int(ModemSound.handshakeSeconds * ModemSound.sampleRate))
    #expect(ModemSound.handshakeSeconds >= 5 && ModemSound.handshakeSeconds <= 8)
}

@Test func dialToneHasBothFrequencies() {
    let s = slice(ModemSound.handshake(), from: 0.1, seconds: 0.5)
    #expect(dominates(s, [350, 440], over: [1000, 697, 2100]))
}

@Test func firstDigitIsFive() {
    let start = ModemSound.start(of: .digits)
    let s = slice(ModemSound.handshake(), from: start + 0.01, seconds: 0.08)
    #expect(dominates(s, [770, 1336], over: [697, 852, 1209, 1477]))
}

@Test func ringBackIs440And480() {
    let s = slice(ModemSound.handshake(), from: ModemSound.start(of: .ringBack) + 0.1, seconds: 0.5)
    #expect(dominates(s, [440, 480], over: [350, 1000, 2100]))
}

@Test func answerToneIs2100() {
    let s = slice(ModemSound.handshake(), from: ModemSound.start(of: .answerTone) + 0.1, seconds: 0.5)
    #expect(dominates(s, [2100], over: [1000, 1200, 2400, 440]))
}

@Test func samplesNeverClip() {
    #expect(ModemSound.handshake().allSatisfy { abs($0) <= 1 })
    #expect(ModemSound.lineNoise(seconds: 3, seed: 1).allSatisfy { abs($0) <= 1 })
}

@Test func noiseIsQuietAndSeeded() {
    let a = ModemSound.lineNoise(seconds: 1, seed: 42)
    #expect(a.count == Int(ModemSound.sampleRate))
    #expect(a.map { abs($0) }.max()! <= 0.06)
    #expect(a.map { abs($0) }.max()! > 0.01)
    #expect(a == ModemSound.lineNoise(seconds: 1, seed: 42))
    #expect(a != ModemSound.lineNoise(seconds: 1, seed: 43))
}
