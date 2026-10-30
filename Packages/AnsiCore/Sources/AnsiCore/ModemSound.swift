import Foundation

/// Synthesized modem sounds: the dial and handshake heard before a BBS answered, and the quiet
/// line noise while art arrived. Everything is generated here; no recordings are used.
/// Samples are mono Float at `sampleRate`, always within -1...1.
public enum ModemSound {
    public static let sampleRate = 22_050.0

    /// The parts of the handshake, in order.
    public enum Segment: CaseIterable {
        case dialTone, digits, pause1, ringBack, pause2, answerTone, training, fade

        public var seconds: Double {
            switch self {
            case .dialTone: return 1.0
            case .digits: return Double(ModemSound.digits.count) * (digitSeconds + digitGap)
            case .pause1, .pause2: return 0.4
            case .ringBack: return 1.0
            case .answerTone: return 1.2
            case .training: return 1.0
            case .fade: return 0.2
            }
        }
    }

    /// A made up 555 number.
    static let digits: [Character] = Array("5550198")
    static let digitSeconds = 0.1
    static let digitGap = 0.07

    public static var handshakeSeconds: Double { Segment.allCases.reduce(0) { $0 + $1.seconds } }

    /// Seconds from the start of the handshake to the start of `segment`.
    public static func start(of segment: Segment) -> Double {
        Segment.allCases.prefix { $0 != segment }.reduce(0) { $0 + $1.seconds }
    }

    /// Dial tone, touch tone digits, ring back, answer tone and a training burst (peak 0.5).
    public static func handshake() -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(Int(handshakeSeconds * sampleRate))
        var noise = Noise(seed: 0x5EED)
        for segment in Segment.allCases {
            switch segment {
            case .dialTone:
                out += tone([350, 440], amplitude: 0.25, seconds: segment.seconds)
            case .digits:
                for digit in digits {
                    out += tone(dtmf(digit), amplitude: 0.25, seconds: digitSeconds)
                    out += silence(digitGap)
                }
            case .pause1, .pause2:
                out += silence(segment.seconds)
            case .ringBack:
                out += tone([440, 480], amplitude: 0.25, seconds: segment.seconds)
            case .answerTone:
                out += tone([2100], amplitude: 0.5, seconds: segment.seconds)
            case .training:
                let carriers = tone([1200, 2400], amplitude: 0.17, seconds: segment.seconds)
                out += carriers.map { $0 + 0.15 * noise.next() }
            case .fade:
                let count = samples(segment.seconds)
                out += (0..<count).map { i in 0.15 * noise.next() * Float(count - i) / Float(count) }
            }
        }
        // Per segment rounding can drift a few samples; the total is exact.
        let total = Int(handshakeSeconds * sampleRate)
        if out.count > total { out.removeLast(out.count - total) }
        while out.count < total { out.append(0) }
        return out
    }

    /// Quiet, slightly muffled hiss for the line while bytes flow (peak 0.06).
    public static func lineNoise(seconds: Double, seed: UInt64) -> [Float] {
        var noise = Noise(seed: seed)
        var smoothed: Float = 0
        var out = (0..<samples(seconds)).map { _ -> Float in
            smoothed = smoothed * 0.6 + noise.next() * 0.4
            return smoothed
        }
        let peak = out.map { abs($0) }.max() ?? 0
        if peak > 0 { out = out.map { $0 * 0.06 / peak } }
        return out
    }

    /// Strength of one frequency in the samples (Goertzel algorithm), normalized by length.
    public static func goertzel(_ samples: ArraySlice<Float>, frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return power / Double(max(1, samples.count * samples.count))
    }

    // MARK: Building blocks

    private static func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    private static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: samples(seconds)) }

    /// Summed sine waves, each at `amplitude`, with 5 ms ramps so tones start and stop without clicks.
    private static func tone(_ frequencies: [Double], amplitude: Float, seconds: Double) -> [Float] {
        let count = samples(seconds)
        let ramp = Double(samples(0.005))
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let value = frequencies.reduce(0.0) { $0 + sin(2 * Double.pi * $1 * t) }
            let edge = min(1, Double(i) / ramp, Double(count - 1 - i) / ramp)
            return amplitude * Float(value * max(0, edge))
        }
    }

    /// The two touch tone frequencies for a digit.
    private static func dtmf(_ digit: Character) -> [Double] {
        let rows: [Double] = [697, 770, 852, 941]
        let columns: [Double] = [1209, 1336, 1477]
        let keys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
        let index = keys.firstIndex(of: digit) ?? 10
        return [rows[index / 3], columns[index % 3]]
    }

    /// Seeded xorshift white noise in -1...1.
    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(state >> 40) / Float(1 << 23) - 1
        }
    }
}
