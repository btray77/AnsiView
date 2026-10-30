import Foundation

// The BASIC PLAY music language as used by "ANSI music". Sources and compatibility rulings:
// docs/superpowers/plans/2026-10-30-ansiview-2.0-music-core.md (GW-BASIC GWSTS.ASM, SyncTERM cterm).

/// How much of a note's time slot sounds: MN 7/8, ML all of it, MS 3/4 (GW-BASIC MSCALE).
public enum Articulation: String, Codable, CaseIterable {
    case normal, legato, staccato

    public var soundingFraction: Double {
        switch self {
        case .normal: return 7.0 / 8.0
        case .legato: return 1
        case .staccato: return 3.0 / 4.0
        }
    }

    /// The PLAY command that selects it.
    public var command: String {
        switch self {
        case .normal: return "MN"
        case .legato: return "ML"
        case .staccato: return "MS"
        }
    }
}

/// Where implementations disagree. GW-BASIC repeats dots (each one multiplies by 1.5);
/// SyncTERM counts any number of dots as one.
public enum PlayDialect: String, Codable, CaseIterable {
    case gwbasic, syncterm
}

/// The music state a PLAY string starts from and leaves behind. ANSI music keeps it from one
/// sequence to the next, like BASIC between PLAY statements.
public struct PlayState: Equatable, Codable {
    /// Quarter notes per minute, 32...255.
    public var tempo = 120
    /// 0...6.
    public var octave = 4
    /// The default note length as a reciprocal of a whole note, 1...64.
    public var length = 4
    public var articulation = Articulation.normal
    /// MB (true) plays while the display continues; MF (false, the default) holds it.
    public var background = false

    public init() {}
}

/// One step of a parsed PLAY string. Octave and default length are resolved into the notes;
/// the commands that change how later notes play stay as items.
public enum PlayItem: Equatable, Codable {
    /// `semitone` 0...83 (octave * 12 + C=0...B=11), or nil for a rest or an unplayable note.
    case note(semitone: Int?, length: Int, dots: Int)
    case tempo(Int)
    case articulation(Articulation)
    case background(Bool)
}

/// A note placed in time, in seconds from the start of its sequence.
public struct TimedNote: Equatable {
    public var semitone: Int?
    /// Hertz; 0 for silence.
    public var frequency: Double
    public var start: Double
    /// How long the tone sounds (the rest of `duration` is silence).
    public var sounding: Double
    /// The whole time slot.
    public var duration: Double
    public var background: Bool

    public init(semitone: Int?, frequency: Double, start: Double, sounding: Double, duration: Double, background: Bool) {
        self.semitone = semitone
        self.frequency = frequency
        self.start = start
        self.sounding = sounding
        self.duration = duration
        self.background = background
    }

    public var end: Double { start + duration }
}

public struct PlayParse: Equatable {
    public var items: [PlayItem]
    public var endState: PlayState
    /// Things that were skipped, for the editor to show. Playback never fails.
    public var warnings: [String]
}

public enum PlayString {
    public static let semitoneRange = 0...83
    /// Longest slot one note may take, however many dots it has.
    public static let maxNoteSeconds = 60.0

    /// Equal temperament anchored on GW-BASIC's octave 6 A of 7040 Hz (octave 0 C is 65.406 Hz).
    public static func frequency(semitone: Int) -> Double {
        7040 * pow(2, Double(semitone - 81) / 12)
    }

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// "O4 C#" style name.
    public static func noteName(_ semitone: Int) -> String {
        "O\(semitone / 12) \(names[((semitone % 12) + 12) % 12])"
    }

    /// The time slot of a note, in seconds.
    public static func slot(tempo: Int, length: Int, dots: Int, dialect: PlayDialect = .gwbasic) -> Double {
        let count = dialect == .syncterm ? min(dots, 1) : dots
        var seconds = 240.0 / Double(max(1, tempo) * max(1, length))
        for _ in 0..<count {
            seconds *= 1.5
            if seconds >= maxNoteSeconds { break }
        }
        return min(seconds, maxNoteSeconds)
    }

    // MARK: Parsing

    public static func parse(_ text: String, from state: PlayState = PlayState(), dialect: PlayDialect = .gwbasic) -> PlayParse {
        let chars = Array(text.utf8).map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }
        var state = state
        var items: [PlayItem] = []
        var warnings: [String] = []
        var i = 0

        func number() -> Int? {
            var value: Int?
            while i < chars.count, (0x30...0x39).contains(chars[i]) {
                value = min(100_000, (value ?? 0) * 10 + Int(chars[i] - 0x30))
                i += 1
            }
            return value
        }
        func dots() -> Int {
            var count = 0
            while i < chars.count, chars[i] == UInt8(ascii: ".") {
                count += 1
                i += 1
            }
            return dialect == .syncterm ? min(count, 1) : count
        }
        func clampLength(_ value: Int?) -> Int {
            guard let value, value > 0 else { return state.length }
            return min(64, value)
        }
        func warn(_ message: String) {
            if warnings.count < 100 { warnings.append(message) }
        }

        while i < chars.count {
            let c = chars[i]
            i += 1
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "G"):
                let base = [9, 11, 0, 2, 4, 5, 7][Int(c - UInt8(ascii: "A"))]
                var shift = 0
                var length = state.length
                var dotCount = 0
                // Modifiers in any order; the last length wins (SyncTERM).
                modifiers: while i < chars.count {
                    switch chars[i] {
                    case UInt8(ascii: "#"), UInt8(ascii: "+"): shift += 1; i += 1
                    case UInt8(ascii: "-"): shift -= 1; i += 1
                    case UInt8(ascii: "0")...UInt8(ascii: "9"): length = clampLength(number())
                    case UInt8(ascii: "."): dotCount = min(dotCount + dots(), 1000)
                    default: break modifiers
                    }
                }
                let semitone = state.octave * 12 + base + shift
                items.append(.note(semitone: semitoneRange.contains(semitone) ? semitone : nil,
                                   length: length, dots: dialect == .syncterm ? min(dotCount, 1) : dotCount))
            case UInt8(ascii: "N"):
                guard let value = number() else { warn("N needs a note number"); continue }
                let semitone: Int? = (1...84).contains(value) ? value - 1 : nil
                items.append(.note(semitone: semitone, length: state.length, dots: dots()))
            case UInt8(ascii: "P"):
                let value = number()
                if value == 0 { _ = dots(); continue }
                items.append(.note(semitone: nil, length: clampLength(value), dots: dots()))
            case UInt8(ascii: "T"):
                guard let value = number() else { warn("T needs a tempo"); continue }
                let tempo = min(255, max(32, value))
                if tempo != state.tempo {
                    state.tempo = tempo
                    items.append(.tempo(tempo))
                }
            case UInt8(ascii: "O"):
                guard let value = number() else { warn("O needs an octave"); continue }
                state.octave = min(6, value)
            case UInt8(ascii: "L"):
                guard let value = number() else { warn("L needs a length"); continue }
                state.length = min(64, max(1, value))
            case UInt8(ascii: "<"):
                state.octave = max(0, state.octave - 1)
            case UInt8(ascii: ">"):
                state.octave = min(6, state.octave + 1)
            case UInt8(ascii: "M"):
                guard i < chars.count else { warn("M needs F, B, N, L or S"); continue }
                let meta = chars[i]
                switch meta {
                case UInt8(ascii: "F"), UInt8(ascii: "B"):
                    i += 1
                    let background = meta == UInt8(ascii: "B")
                    if background != state.background {
                        state.background = background
                        items.append(.background(background))
                    }
                case UInt8(ascii: "N"), UInt8(ascii: "L"), UInt8(ascii: "S"):
                    i += 1
                    let articulation: Articulation = meta == UInt8(ascii: "N") ? .normal : meta == UInt8(ascii: "L") ? .legato : .staccato
                    if articulation != state.articulation {
                        state.articulation = articulation
                        items.append(.articulation(articulation))
                    }
                default:
                    warn("M needs F, B, N, L or S")
                }
            case UInt8(ascii: " "), 0x09:
                continue
            default:
                warn("Skipped \"\(String(UnicodeScalar(c)))\"")
            }
        }
        return PlayParse(items: items, endState: state, warnings: warnings)
    }

    // MARK: Timing

    public static func schedule(_ items: [PlayItem], from state: PlayState = PlayState(), dialect: PlayDialect = .gwbasic,
                                start: Double = 0) -> [TimedNote] {
        var state = state
        var time = start
        var result: [TimedNote] = []
        for item in items {
            switch item {
            case .tempo(let tempo): state.tempo = tempo
            case .articulation(let articulation): state.articulation = articulation
            case .background(let background): state.background = background
            case .note(let semitone, let length, let dots):
                let duration = slot(tempo: state.tempo, length: length, dots: dots, dialect: dialect)
                let sounding = semitone == nil ? 0 : duration * state.articulation.soundingFraction
                result.append(TimedNote(semitone: semitone, frequency: semitone.map(frequency(semitone:)) ?? 0,
                                        start: time, sounding: sounding, duration: duration, background: state.background))
                time += duration
            }
        }
        return result
    }

    // MARK: Serializing

    /// A canonical PLAY string for `items` that parses back to the same items from `state`.
    public static func serialize(_ items: [PlayItem], from state: PlayState = PlayState()) -> String {
        var state = state
        var tokens: [String] = []
        for (index, item) in items.enumerated() {
            switch item {
            case .tempo(let tempo):
                if tempo != state.tempo { tokens.append("T\(tempo)"); state.tempo = tempo }
            case .articulation(let articulation):
                if articulation != state.articulation { tokens.append(articulation.command); state.articulation = articulation }
            case .background(let background):
                if background != state.background { tokens.append(background ? "MB" : "MF"); state.background = background }
            case .note(let semitone, let length, let dots):
                let dotText = String(repeating: ".", count: dots)
                guard let semitone else {
                    tokens.append("P\(length)\(dotText)")
                    continue
                }
                var suffix = ""
                if length != state.length {
                    // Change L when the next note uses the same length too, else use a suffix.
                    if nextNoteLength(items, after: index) == length {
                        tokens.append("L\(length)")
                        state.length = length
                    } else {
                        suffix = "\(length)"
                    }
                }
                if semitone / 12 != state.octave {
                    state.octave = semitone / 12
                    tokens.append("O\(state.octave)")
                }
                tokens.append(names[semitone % 12] + suffix + dotText)
            }
        }
        return tokens.joined(separator: " ")
    }

    private static func nextNoteLength(_ items: [PlayItem], after index: Int) -> Int? {
        for item in items[(index + 1)...] {
            if case .note(let semitone, let length, _) = item, semitone != nil { return length }
        }
        return nil
    }
}
