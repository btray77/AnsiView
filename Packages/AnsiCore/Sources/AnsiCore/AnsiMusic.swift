import Foundation

// ANSI music in byte streams: `ESC [ M`, `ESC [ N` or `ESC [ |`, a BASIC PLAY string, then 0x0E.
// Behaviour follows SyncTERM's cterm (see docs/superpowers/plans/2026-10-30-ansiview-2.0-music-core.md).

/// Which introducers start music. Matches SyncTERM's `CSI = Ps M` settings plus Off.
public enum MusicMode: Int, CaseIterable, Codable {
    /// Nothing is music; the sequences are ignored and their text prints.
    case off
    /// Only `ESC[|` (SyncTERM `CSI = 0 M`).
    case pipe
    /// `ESC[|` and BananaCom's `ESC[N` (`CSI = 1 M`, SyncTERM's default for a terminal).
    case bananaCom
    /// Also `ESC[M` with no parameter (`CSI = 2 M`); Delete Line then needs a parameter.
    case all

    public var title: String {
        switch self {
        case .off: return "Off"
        case .pipe: return "ESC[| only"
        case .bananaCom: return "ESC[| and ESC[N"
        case .all: return "All (ESC[M, ESC[N, ESC[|)"
        }
    }

    public var help: String {
        switch self {
        case .off: return "Music sequences are not recognised and their text is shown."
        case .pipe: return "Only SyncTERM's ESC[| starts music. Safest for terminals."
        case .bananaCom: return "ESC[| and BananaCom's ESC[N start music. SyncTERM's default."
        case .all: return "ESC[M also starts music, as in Qmodem, Telix and TeleMate. ESC[M then cannot mean Delete Line unless it has a number."
        }
    }

    /// The dialing directory's names (BANSI is SyncTERM's name for ESC[| plus ESC[N).
    public var entryLabel: String {
        switch self {
        case .off: return "Off"
        case .pipe: return "ESC[| only"
        case .bananaCom: return "BANSI: ESC[| and ESC[N"
        case .all: return "All: also ESC[M"
        }
    }

    /// The entry editor's hint for the music mode.
    public static let entryHint = "BBS tunes after ESC[M, ESC[N or ESC[|. MF music holds the screen, MB does not. "
        + "BANSI: ESC[| and ESC[N (SyncTERM). All adds ESC[M."

    /// Whether a CSI with no parameters and this final byte starts music.
    public func introduces(_ final: UInt8) -> Bool {
        switch final {
        case UInt8(ascii: "|"): return self != .off
        case UInt8(ascii: "N"): return self == .bananaCom || self == .all
        case UInt8(ascii: "M"): return self == .all
        default: return false
        }
    }

    /// The mode a `CSI = Ps M` selects, or nil when `Ps` is not 0, 1 or 2.
    static func ctsam(_ value: Int) -> MusicMode? {
        [0: .pipe, 1: .bananaCom, 2: .all][value]
    }
}

public enum MusicIntroducer: String, Codable, CaseIterable {
    case m = "M", n = "N", pipe = "|"

    init?(final: UInt8) {
        self.init(rawValue: String(UnicodeScalar(final)))
    }

    var final: UInt8 { Array(rawValue.utf8)[0] }

    /// `ESC[M` and `ESC[|` read a leading B, F, L, S (or N without a number) as MB, MF, ML, MS, MN.
    var usesFirstCharacterRule: Bool { self != .n }
}

/// One music sequence found in a stream.
public struct MusicSequence: Equatable {
    /// Index of the ESC in the stream (`ArtFile.stream` coordinates, the same as `AnsiTerminal.position`).
    public var offset: Int
    /// Bytes from the ESC through the 0x0E (or up to where the sequence stopped).
    public var length: Int
    public var introducer: MusicIntroducer
    /// The PLAY string as sent (without the first character rule's implied M).
    public var body: String
    /// False when the sequence was cut off by a byte that is not allowed in music, or by the end of
    /// the stream. Such sequences are removed from the display but not played (SyncTERM).
    public var isTerminated: Bool
    public var startState: PlayState
    public var items: [PlayItem]
    /// Times are relative to the start of this sequence.
    public var notes: [TimedNote]
    public var warnings: [String]

    public var duration: Double { notes.last?.end ?? 0 }
    /// Foreground (MF) music holds the display until it finishes; background (MB) does not.
    public var blocksDisplay: Bool { notes.contains { !$0.background } }
    public var end: Int { offset + length }
}

public struct MusicScan: Equatable {
    public var sequences: [MusicSequence]
    /// The stream with the music sequences (and a 0x0F directly after one) removed.
    public var visual: [UInt8]
    public var shiftInsDropped: Int

    /// Terminated sequences, which are the ones that play.
    public var playable: [MusicSequence] { sequences.filter(\.isTerminated) }
}

/// Finds music in a stream fed in pieces (for example network packets). Keeps the play state
/// (tempo, octave, length, articulation, MF/MB) from one sequence to the next.
public struct MusicStreamFilter {
    public private(set) var mode: MusicMode
    public let dialect: PlayDialect
    public private(set) var playState = PlayState()
    public private(set) var shiftInsDropped = 0
    /// Absolute index of the next byte.
    public private(set) var consumed = 0

    static let maxBody = 65536
    static let maxCSI = 4096

    private enum Phase {
        case text
        case escape(start: Int)
        case csi(start: Int, bytes: [UInt8])
        /// A CSI too long to buffer: pass it through until its final byte.
        case csiPassThrough
        case body(start: Int, introducer: MusicIntroducer, body: [UInt8], length: Int)
        case afterMusic
    }

    private var phase = Phase.text

    public init(mode: MusicMode = .all, dialect: PlayDialect = .gwbasic) {
        self.mode = mode
        self.dialect = dialect
    }

    public mutating func feed(_ bytes: [UInt8]) -> (visual: [UInt8], finished: [MusicSequence]) {
        var visual: [UInt8] = []
        var finished: [MusicSequence] = []
        visual.reserveCapacity(bytes.count)
        for byte in bytes {
            process(byte, &visual, &finished)
            consumed += 1
        }
        return (visual, finished)
    }

    /// Call at the end of the stream: an open sequence is reported unterminated, and the bytes
    /// of a partial escape sequence held back so far are returned as visual bytes.
    public mutating func finish() -> (visual: [UInt8], finished: [MusicSequence]) {
        let held = pending
        defer { phase = .text }
        if case .body(let start, let introducer, let body, let length) = phase {
            return (held, [sequence(start: start, introducer: introducer, body: body, length: length, terminated: false)])
        }
        return (held, [])
    }

    /// Bytes held back because they may start a music sequence (an ESC or an unfinished CSI).
    public var pending: [UInt8] {
        switch phase {
        case .escape: return [0x1B]
        case .csi(_, let bytes): return [0x1B] + bytes
        default: return []
        }
    }

    private mutating func process(_ byte: UInt8, _ visual: inout [UInt8], _ finished: inout [MusicSequence]) {
        switch phase {
        case .text:
            if byte == 0x1B { phase = .escape(start: consumed) } else { visual.append(byte) }
        case .afterMusic:
            phase = .text
            if byte == 0x0F {
                shiftInsDropped += 1
            } else {
                process(byte, &visual, &finished)
            }
        case .escape(let start):
            if byte == 0x5B {
                phase = .csi(start: start, bytes: [byte])
            } else {
                // Like AnsiTerminal: ESC and the byte after it are skipped together.
                visual += [0x1B, byte]
                phase = .text
            }
        case .csi(let start, var bytes):
            if (0x40...0x7E).contains(byte) {
                if bytes.count == 1, mode.introduces(byte), let introducer = MusicIntroducer(final: byte) {
                    phase = .body(start: start, introducer: introducer, body: [], length: 3)
                    return
                }
                if byte == UInt8(ascii: "M"), bytes.count >= 2, bytes[1] == UInt8(ascii: "="), mode != .off {
                    if let selected = MusicMode.ctsam(AnsiMusic.firstParameter(bytes.dropFirst())) { mode = selected }
                }
                visual += [0x1B] + bytes + [byte]
                phase = .text
            } else if bytes.count >= Self.maxCSI {
                visual += [0x1B] + bytes + [byte]
                phase = .csiPassThrough
            } else {
                bytes.append(byte)
                phase = .csi(start: start, bytes: bytes)
            }
        case .csiPassThrough:
            visual.append(byte)
            if (0x40...0x7E).contains(byte) { phase = .text }
        case .body(let start, let introducer, var body, let length):
            if byte == 0x0E {
                finished.append(sequence(start: start, introducer: introducer, body: body, length: length + 1, terminated: true))
                phase = .afterMusic
            } else if AnsiMusic.allowed.contains(byte) {
                if body.count < Self.maxBody { body.append(byte) }
                phase = .body(start: start, introducer: introducer, body: body, length: length + 1)
            } else {
                finished.append(sequence(start: start, introducer: introducer, body: body, length: length, terminated: false))
                phase = .text
                process(byte, &visual, &finished)
            }
        }
    }

    private mutating func sequence(start: Int, introducer: MusicIntroducer, body: [UInt8], length: Int,
                                   terminated: Bool) -> MusicSequence {
        let text = String(decoding: body, as: UTF8.self)
        var result = MusicSequence(offset: start, length: length, introducer: introducer, body: text,
                                   isTerminated: terminated, startState: playState, items: [], notes: [], warnings: [])
        guard terminated else { return result }
        let parsed = PlayString.parse(AnsiMusic.applyFirstCharacterRule(text, introducer: introducer),
                                      from: playState, dialect: dialect)
        result.items = parsed.items
        result.warnings = parsed.warnings
        result.notes = PlayString.schedule(parsed.items, from: playState, dialect: dialect)
        playState = parsed.endState
        return result
    }
}

public enum AnsiMusic {
    /// Bytes allowed inside a music string (SyncTERM `musicchars`); anything else ends it.
    public static let allowed: Set<UInt8> = Set("aAbBcCdDeEfFgGlLmMnNoOpPsStT0123456789.-+#<> ".utf8)

    public static func scan(_ stream: [UInt8], mode: MusicMode = .all, dialect: PlayDialect = .gwbasic) -> MusicScan {
        var filter = MusicStreamFilter(mode: mode, dialect: dialect)
        var (visual, sequences) = filter.feed(stream)
        let end = filter.finish()
        visual += end.visual
        sequences += end.finished
        return MusicScan(sequences: sequences, visual: visual, shiftInsDropped: filter.shiftInsDropped)
    }

    /// The music of all playable sequences one after another, as a single timeline.
    public static func timeline(_ sequences: [MusicSequence]) -> [TimedNote] {
        var time = 0.0
        var result: [TimedNote] = []
        for sequence in sequences where sequence.isTerminated {
            for var note in sequence.notes {
                note.start += time
                result.append(note)
            }
            time += sequence.duration
        }
        return result
    }

    /// For the file player: where the music sequence that starts at `index` (just after `ESC [ final`)
    /// ends. Returns the index after the 0x0E (and a following 0x0F), or the index of the byte that
    /// stopped it, or the end of `bytes`.
    static func skipBody(_ bytes: [UInt8], from index: Int) -> Int {
        var i = index
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0E {
                i += 1
                if i < bytes.count, bytes[i] == 0x0F { i += 1 }
                return i
            }
            guard allowed.contains(b) else { return i }
            i += 1
        }
        return i
    }

    /// The first CSI parameter the way AnsiTerminal reads it: digits up to the first `;`, other
    /// bytes (private markers, intermediates, controls) ignored; 0 when there is none.
    static func firstParameter(_ csi: ArraySlice<UInt8>) -> Int {
        var value: Int?
        for byte in csi {
            if (0x30...0x39).contains(byte) {
                value = min(9999, (value ?? 0) * 10 + Int(byte - 0x30))
            } else if byte == 0x3B {
                break
            }
        }
        return value ?? 0
    }

    static func applyFirstCharacterRule(_ text: String, introducer: MusicIntroducer) -> String {
        guard introducer.usesFirstCharacterRule, let first = text.utf8.first else { return text }
        let upper = (0x61...0x7A).contains(first) ? first - 0x20 : first
        if Array("BFLS".utf8).contains(upper) { return "M" + text }
        if upper == UInt8(ascii: "N") {
            let next = text.utf8.dropFirst().first
            if next == nil || !(0x30...0x39).contains(next!) { return "M" + text }
        }
        return text
    }

    /// The escape sequence that plays `play`: `ESC [ introducer`, the PLAY string, 0x0E, and an
    /// optional 0x0F (SyncTERM recommends it so other terminals undo the shift out).
    public static func escape(_ play: String, introducer: MusicIntroducer = .m, shiftIn: Bool = true) -> [UInt8] {
        var body: [UInt8] = []
        for byte in play.utf8 {
            if byte == 0x0A || byte == 0x0D || byte == 0x09 {
                body.append(0x20)
            } else if allowed.contains(byte) {
                body.append(byte)
            }
        }
        // Keep a leading note B, F, L... from being read as MB, MF, ML.
        let text = String(decoding: body, as: UTF8.self)
        if applyFirstCharacterRule(text, introducer: introducer) != text { body.insert(0x20, at: 0) }
        return [0x1B, 0x5B, introducer.final] + body + [0x0E] + (shiftIn ? [0x0F] : [])
    }

    public enum EmbedPosition: Equatable {
        case start
        /// The end of the art, before a DOS end of file marker and SAUCE.
        case end
        /// After the Nth line feed of the art (the end when the art has fewer lines).
        case afterLine(Int)
    }

    /// `file` with `sequence` inserted. Everything else is kept byte for byte; only the SAUCE
    /// FileSize field grows by the inserted length.
    public static func embed(_ sequence: [UInt8], into file: [UInt8], at position: EmbedPosition) -> [UInt8] {
        let (sauce, contentLength) = Sauce.read(file)
        let artEnd = file[..<contentLength].firstIndex(of: 0x1A) ?? contentLength
        let index: Int
        switch position {
        case .start: index = 0
        case .end: index = artEnd
        case .afterLine(let line):
            var count = 0
            var found = artEnd
            if line <= 0 { found = 0 } else {
                for i in 0..<artEnd where file[i] == 0x0A {
                    count += 1
                    if count == line { found = i + 1; break }
                }
            }
            index = found
        }
        var out = file
        out.insert(contentsOf: sequence, at: index)
        if sauce != nil {
            let field = out.count - Sauce.recordLength + 90
            var size = UInt32(out[field]) | UInt32(out[field + 1]) << 8 | UInt32(out[field + 2]) << 16 | UInt32(out[field + 3]) << 24
            // 0 means "unknown" in SAUCE; leave it so.
            if size != 0 {
                size = size &+ UInt32(clamping: sequence.count)
                for k in 0..<4 { out[field + k] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(k))) }
            }
        }
        return out
    }
}
