import Foundation

/// The editable tune behind the ANSI Music Editor: PLAY items from the default state, kept in
/// canonical form so the piano roll and the PLAY text always agree. Monophonic, like PLAY.
public struct MusicTune: Equatable, Codable {
    public private(set) var items: [PlayItem]

    public init(items: [PlayItem] = [], startingFrom state: PlayState = PlayState()) {
        var prefix: [PlayItem] = []
        let base = PlayState()
        if state.tempo != base.tempo { prefix.append(.tempo(state.tempo)) }
        if state.articulation != base.articulation { prefix.append(.articulation(state.articulation)) }
        if state.background != base.background { prefix.append(.background(state.background)) }
        self.items = Self.normalized(prefix + items)
    }

    public init(play: String) {
        self.items = PlayString.parse(play).items
        self.items = Self.normalized(items)
    }

    /// The canonical PLAY string.
    public var play: String { PlayString.serialize(items) }
    public var notes: [TimedNote] { PlayString.schedule(items) }
    public var duration: Double { notes.last?.end ?? 0 }

    private static func normalized(_ items: [PlayItem]) -> [PlayItem] {
        PlayString.parse(PlayString.serialize(items)).items
    }

    private mutating func normalize() { items = Self.normalized(items) }

    // MARK: Layout in whole notes (tempo changes do not move notes)

    public struct Placed: Equatable {
        /// Index into `items`.
        public var index: Int
        public var semitone: Int?
        /// Start, in whole notes from the beginning.
        public var position: Double
        /// Length in whole notes.
        public var length: Double
        public var lengthValue: Int
        public var dots: Int

        public var end: Double { position + length }
    }

    public static func wholeNotes(length: Int, dots: Int) -> Double {
        var value = 1.0 / Double(max(1, length))
        for _ in 0..<min(dots, 8) { value *= 1.5 }
        return value
    }

    public var placed: [Placed] {
        var position = 0.0
        var result: [Placed] = []
        for (index, item) in items.enumerated() {
            guard case .note(let semitone, let length, let dots) = item else { continue }
            let size = Self.wholeNotes(length: length, dots: dots)
            result.append(Placed(index: index, semitone: semitone, position: position, length: size, lengthValue: length, dots: dots))
            position += size
        }
        return result
    }

    public var totalLength: Double { placed.last?.end ?? 0 }

    private static let epsilon = 1e-9

    /// The note or rest covering `position`, if any.
    public func placed(at position: Double) -> Placed? {
        placed.first { position >= $0.position - Self.epsilon && position < $0.end - Self.epsilon }
    }

    // MARK: Editing

    /// Puts a note at `position` (whole notes): past the end the gap fills with rests; inside a
    /// rest the rest splits; on a note the note changes pitch. Returns the note's item index.
    @discardableResult
    public mutating func addNote(semitone: Int, at position: Double, length: Int, dots: Int = 0) -> Int {
        let semitone = min(PlayString.semitoneRange.upperBound, max(0, semitone))
        let length = min(64, max(1, length))
        guard let hit = placed(at: max(0, position)) else {
            let gap = max(0, position) - totalLength
            if gap > Self.epsilon {
                items += Self.restFill(gap).map { .note(semitone: nil, length: $0, dots: 0) }
            }
            items.append(.note(semitone: semitone, length: length, dots: dots))
            normalize()
            return placed.last?.index ?? 0
        }
        if hit.semitone != nil {
            setPitch(index: hit.index, semitone: semitone)
            return hit.index
        }
        let before = max(0, position) - hit.position
        let size = Self.wholeNotes(length: length, dots: dots)
        let after = hit.length - before - size
        var replacement: [PlayItem] = Self.restFill(before).map { .note(semitone: nil, length: $0, dots: 0) }
        let noteIndex = hit.index + replacement.count
        replacement.append(.note(semitone: semitone, length: length, dots: dots))
        if after > Self.epsilon { replacement += Self.restFill(after).map { .note(semitone: nil, length: $0, dots: 0) } }
        items.replaceSubrange(hit.index...hit.index, with: replacement)
        normalize()
        return noteIndex
    }

    public mutating func setPitch(index: Int, semitone: Int) {
        guard items.indices.contains(index), case .note(_, let length, let dots) = items[index] else { return }
        items[index] = .note(semitone: min(PlayString.semitoneRange.upperBound, max(0, semitone)), length: length, dots: dots)
        normalize()
    }

    /// Sets a note's length to the nearest PLAY length; later notes move.
    public mutating func setLength(index: Int, wholeNotes: Double) {
        guard items.indices.contains(index), case .note(let semitone, _, _) = items[index] else { return }
        let nearest = Self.nearestLength(wholeNotes)
        items[index] = .note(semitone: semitone, length: nearest.length, dots: nearest.dots)
        normalize()
    }

    /// Turns a note into a rest of the same length (so later notes stay put); rests at the end go.
    public mutating func delete(index: Int) {
        guard items.indices.contains(index), case .note(_, let length, let dots) = items[index] else { return }
        items[index] = .note(semitone: nil, length: length, dots: dots)
        // Rests at the end, and commands after the last note (they change nothing), go.
        while let last = items.last {
            if case .note(let semitone, _, _) = last, semitone != nil { break }
            items.removeLast()
        }
        normalize()
    }

    public mutating func append(semitone: Int?, length: Int, dots: Int) {
        items.append(.note(semitone: semitone.map { min(83, max(0, $0)) }, length: min(64, max(1, length)), dots: max(0, dots)))
        normalize()
    }

    /// Inserts `other` before item `index`, with its own tempo, articulation and MF/MB, and puts
    /// those back afterwards so the rest of the tune plays as before.
    public mutating func insert(_ other: MusicTune, at index: Int) {
        let index = min(max(0, index), items.count)
        let before = Self.state(of: Array(items[..<index]))
        let inside = Self.state(of: other.items)
        var middle: [PlayItem] = []
        let base = PlayState()
        if before.tempo != base.tempo { middle.append(.tempo(base.tempo)) }
        if before.articulation != base.articulation { middle.append(.articulation(base.articulation)) }
        if before.background != base.background { middle.append(.background(base.background)) }
        middle += other.items
        if index < items.count {
            if inside.tempo != before.tempo { middle.append(.tempo(before.tempo)) }
            if inside.articulation != before.articulation { middle.append(.articulation(before.articulation)) }
            if inside.background != before.background { middle.append(.background(before.background)) }
        }
        items.insert(contentsOf: middle, at: index)
        normalize()
    }

    /// Tempo, articulation and MF/MB after `items`.
    static func state(of items: [PlayItem]) -> PlayState {
        var state = PlayState()
        for item in items {
            switch item {
            case .tempo(let tempo): state.tempo = tempo
            case .articulation(let articulation): state.articulation = articulation
            case .background(let background): state.background = background
            case .note: break
            }
        }
        return state
    }

    /// Where a click at `raw` whole notes puts a new note: on the grid, but never earlier than the
    /// end of the tune (past the end) or the start of the rest it falls in, so it cannot land on
    /// the note before.
    public func snappedPosition(_ raw: Double, grid: Double) -> Double {
        let raw = max(0, raw)
        var snapped = grid > 0 ? (raw / grid + Self.epsilon).rounded(.down) * grid : raw
        if raw >= totalLength - Self.epsilon {
            snapped = max(snapped, totalLength)
        } else if let hit = placed(at: raw) {
            snapped = max(snapped, hit.position)
        }
        return snapped
    }

    /// The PLAY string with the full starting state spelled out (tempo, length, articulation,
    /// MF/MB and octave), so it plays the same after any other music in a stream. Use it for export.
    public var selfContainedPlay: String {
        let lead = leadingCount
        let state = Self.state(of: Array(items[..<lead]))
        let rest = Array(items[lead...])
        var firstLength = 4
        for item in rest {
            if case .note(let semitone, let length, _) = item, semitone != nil { firstLength = length; break }
        }
        var start = PlayState()
        start.tempo = state.tempo
        start.articulation = state.articulation
        start.background = state.background
        start.length = firstLength
        start.octave = -1  // forces an O before the first note
        let head = "T\(state.tempo) L\(firstLength) \(state.articulation.command) \(state.background ? "MB" : "MF")"
        let body = PlayString.serialize(rest, from: start)
        return body.isEmpty ? head : head + " " + body
    }

    // MARK: Starting tempo, articulation and mode (the commands before the first note)

    private var leadingCount: Int { items.firstIndex { if case .note = $0 { return true } else { return false } } ?? items.count }

    private mutating func setLeading(_ make: (PlayState) -> PlayState) {
        let leading = Array(items[..<leadingCount])
        let state = make(Self.state(of: leading))
        var prefix: [PlayItem] = []
        if state.tempo != 120 { prefix.append(.tempo(state.tempo)) }
        if state.articulation != .normal { prefix.append(.articulation(state.articulation)) }
        if state.background { prefix.append(.background(true)) }
        items.replaceSubrange(0..<leadingCount, with: prefix)
        normalize()
    }

    public var tempo: Int {
        get { Self.state(of: Array(items[..<leadingCount])).tempo }
        set { setLeading { var s = $0; s.tempo = min(255, max(32, newValue)); return s } }
    }

    public var articulation: Articulation {
        get { Self.state(of: Array(items[..<leadingCount])).articulation }
        set { setLeading { var s = $0; s.articulation = newValue; return s } }
    }

    public var background: Bool {
        get { Self.state(of: Array(items[..<leadingCount])).background }
        set { setLeading { var s = $0; s.background = newValue; return s } }
    }

    // MARK: Lengths

    private static let candidates: [(length: Int, dots: Int)] = {
        var list: [(Int, Int)] = []
        for length in [1, 2, 4, 8, 16, 32, 64] { for dots in 0...2 { list.append((length, dots)) } }
        for length in [3, 6, 12, 24, 48] { list.append((length, 0)) }
        return list
    }()

    /// The PLAY length (powers of two with up to two dots, or a triplet length) nearest `wholeNotes`.
    public static func nearestLength(_ wholeNotes: Double) -> (length: Int, dots: Int) {
        var best = candidates[0]
        var bestError = Double.infinity
        for candidate in candidates {
            let error = abs(Self.wholeNotes(length: candidate.length, dots: candidate.dots) - wholeNotes)
            if error < bestError - epsilon {
                best = candidate
                bestError = error
            }
        }
        return best
    }

    /// Rest lengths (largest first) that fill `wholeNotes`; less than a 1/64 left over is dropped.
    public static func restFill(_ wholeNotes: Double) -> [Int] {
        var remaining = wholeNotes
        var result: [Int] = []
        while remaining >= 1.0 / 64 - epsilon, result.count < 10_000 {
            let length = [1, 2, 4, 8, 16, 32, 64].first { 1.0 / Double($0) <= remaining + epsilon } ?? 64
            result.append(length)
            remaining -= 1.0 / Double(length)
        }
        return result
    }
}

/// Computer keyboard note entry: the home row as a piano (a = C, w = C#, ... k = C an octave up),
/// number keys for lengths.
public enum MusicKeyboard {
    private static let keys: [Character: Int] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6, "g": 7, "y": 8, "h": 9, "u": 10, "j": 11, "k": 12,
    ]

    public static func semitoneOffset(for key: Character) -> Int? {
        keys[Character(key.lowercased())]
    }

    /// 1...7 select whole, half, quarter, eighth, 16th, 32nd and 64th notes.
    public static func length(for key: Character) -> Int? {
        guard let digit = key.wholeNumberValue, (1...7).contains(digit) else { return nil }
        return 1 << (digit - 1)
    }
}

/// Named PLAY snippets the user keeps for reuse.
public struct MusicLibrary: Codable, Equatable {
    public struct Snippet: Codable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var play: String

        public init(id: UUID = UUID(), name: String, play: String) {
            self.id = id
            self.name = name
            self.play = play
        }
    }

    public var version = 1
    public var snippets: [Snippet] = []

    public init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    private enum CodingKeys: String, CodingKey { case version, snippets }

    /// Lenient: a missing version or id is fine, and one unreadable entry does not lose the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        var list = try container.nestedUnkeyedContainer(forKey: .snippets)
        var result: [Snippet] = []
        while !list.isAtEnd {
            if let entry = try? list.decode(LenientSnippet.self), let snippet = entry.snippet {
                result.append(snippet)
            } else {
                _ = try? list.decode(Discard.self)
            }
        }
        snippets = result
    }

    private struct LenientSnippet: Decodable {
        let snippet: Snippet?
        private enum Keys: String, CodingKey { case id, name, play }
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Keys.self),
                  let name = try? container.decode(String.self, forKey: .name),
                  let play = try? container.decode(String.self, forKey: .play) else { snippet = nil; return }
            let id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
            snippet = Snippet(id: id, name: name, play: play)
        }
    }

    /// Consumes one element of any type.
    private struct Discard: Decodable {
        init(from decoder: Decoder) throws {}
    }

    @discardableResult
    public mutating func add(name: String, play: String) -> Snippet {
        let snippet = Snippet(name: name, play: play)
        snippets.append(snippet)
        return snippet
    }

    public mutating func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Unreadable data gives an empty library.
    public static func decode(_ data: Data) -> MusicLibrary {
        (try? JSONDecoder().decode(MusicLibrary.self, from: data)) ?? MusicLibrary()
    }
}

/// Sample tunes: public domain melodies written out for AnsiView, and original pieces.
public enum MusicDemos {
    public struct Demo {
        public let title: String
        public let play: String
        public let credit: String
    }

    public static let all: [Demo] = [
        Demo(title: "Ode to Joy",
             play: "T120 O3 L4 E E F G G F E D C C D E E. D8 D2 E E F G G F E D C C D E D. C8 C2",
             credit: "Melody by Ludwig van Beethoven (1824), public domain; written out for AnsiView"),
        Demo(title: "Twinkle, Twinkle, Little Star",
             play: "T140 O3 L4 C C G G A A G2 F F E E D D C2 G G F F E E D2 G G F F E E D2 C C G G A A G2 F F E E D D C2",
             credit: "Traditional French melody, public domain; written out for AnsiView"),
        Demo(title: "Greensleeves",
             play: "T140 O2 L4 A > C2 D E. F8 E D2 < B G. A8 B > C2 < A A. G#8 A B2 G# E2 A > C2 D E. F8 E D2 < B G. A8 B > C. < B8 A G#. F#8 G# A2. A2.",
             credit: "Traditional English melody, public domain; written out for AnsiView"),
        Demo(title: "Modem Dawn",
             play: "T160 O2 L8 C E G > C < G E C4 P8 D F A > D < A F D4 P8 E G# B > E < B G# E4 MS > C C C ML C2.",
             credit: "Original composition for AnsiView"),
        Demo(title: "Sysop's Blues",
             play: "T110 O2 L8 C E G A A# A G E F A > C D D# D C < A C E G A A# A G E G B > D E F E D < B C E G > C4. P8 < C2",
             credit: "Original composition for AnsiView"),
        Demo(title: "Download Complete",
             play: "T200 O3 L16 MS C E G > C8 P16 < G > C4 ML E2",
             credit: "Original composition for AnsiView"),
    ]
}
