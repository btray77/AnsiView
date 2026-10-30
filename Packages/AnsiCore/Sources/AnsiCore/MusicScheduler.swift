import Foundation

// When ANSI music plays while art is shown: in the file player at baud speed, in the BBS terminal
// as bytes arrive, and in exported video. Pure and clock injected: every call takes the time.
// See docs/superpowers/plans/2026-10-30-ansiview-2.0-music-playback.md (rulings 1 to 9).

/// One music sequence placed on the clock.
public struct ScheduledMusic: Equatable {
    public var sequence: MusicSequence
    /// Clock time the first note sounds.
    public var start: Double
    /// True when the display waits for this music (foreground music in a viewer or terminal).
    public var holds: Bool

    public var end: Double { start + sequence.duration }
    public var notes: [TimedNote] { sequence.notes }
}

/// What the audio output should do.
public enum MusicEvent: Equatable {
    /// Queue these notes after anything already queued (the scheduler's start time says when).
    case play(ScheduledMusic)
    case pause
    case resume
    /// Silence everything queued.
    case stop
}

/// One speaker. Music plays in arrival order, each sequence when the one before has ended (the
/// GW-BASIC and SyncTERM note queue). Foreground music holds the display until the queue drains.
public struct MusicQueue: Equatable {
    /// Music not yet finished when the last sequence was added, in order.
    public private(set) var scheduled: [ScheduledMusic] = []
    /// When the speaker is free again.
    public private(set) var freeAt: Double?
    /// The display waits until this time.
    public private(set) var holdUntil: Double?
    public private(set) var pausedAt: Double?

    public init() {}

    /// Queues `sequence` at `now`. `holds` defaults to the sequence's own foreground flag.
    @discardableResult
    public mutating func add(_ sequence: MusicSequence, at now: Double, holds: Bool? = nil) -> ScheduledMusic {
        let time = pausedAt ?? now
        scheduled.removeAll { $0.end <= time }
        let start = max(time, freeAt ?? time)
        let music = ScheduledMusic(sequence: sequence, start: start, holds: holds ?? sequence.blocksDisplay)
        scheduled.append(music)
        freeAt = music.end
        if music.holds { holdUntil = music.end }
        return music
    }

    public func isHolding(at now: Double) -> Bool {
        guard let holdUntil else { return false }
        return (pausedAt ?? now) < holdUntil
    }

    /// The music sounding at `now`, if any.
    public func playing(at now: Double) -> ScheduledMusic? {
        let time = pausedAt ?? now
        return scheduled.first { $0.start <= time && time < $0.end }
    }

    /// True while anything is queued or sounding.
    public func isActive(at now: Double) -> Bool {
        guard let freeAt else { return false }
        return (pausedAt ?? now) < freeAt
    }

    /// Freezes the clock for the queue. Returns false when nothing was playing.
    @discardableResult
    public mutating func pause(at now: Double) -> Bool {
        guard pausedAt == nil else { return false }
        let active = isActive(at: now)
        pausedAt = now
        return active
    }

    /// Moves every time on by the paused span. Returns the span (0 when not paused).
    @discardableResult
    public mutating func resume(at now: Double) -> Double {
        guard let pausedAt else { return 0 }
        let delta = max(0, now - pausedAt)
        self.pausedAt = nil
        for i in scheduled.indices { scheduled[i].start += delta }
        freeAt = freeAt.map { $0 + delta }
        holdUntil = holdUntil.map { $0 + delta }
        return delta
    }

    public mutating func clear() {
        scheduled = []
        freeAt = nil
        holdUntil = nil
        pausedAt = nil
    }
}

/// The file player's music: which sequence the playback cursor passes next, when its music starts,
/// and whether the drawing waits for it.
public struct MusicPlaybackScheduler {
    /// Playable (terminated) sequences in stream order.
    public let sequences: [MusicSequence]
    /// The first sequence the cursor has not passed yet.
    public private(set) var next = 0
    public private(set) var queue = MusicQueue()
    /// Every sequence started since the last stop or seek, with its clock times.
    public private(set) var started: [ScheduledMusic] = []

    public init(_ sequences: [MusicSequence]) {
        self.sequences = sequences.filter(\.isTerminated).sorted { $0.offset < $1.offset }
    }

    /// The music of `file`, found the way the file player reads it (`AnsiTerminal`'s default mode).
    public init(file: ArtFile) {
        self.init(AnsiMusic.scan(file.stream, mode: .all).playable)
    }

    public var hasMusic: Bool { !sequences.isEmpty }

    /// Where the drawing must stop so the next music starts on time: the end of the next sequence.
    public var limit: Int? { next < sequences.count ? sequences[next].end : nil }

    public func isHolding(at now: Double) -> Bool { queue.isHolding(at: now) }

    /// Starts the music of every sequence the cursor has passed at `position`.
    public mutating func reached(_ position: Int, at now: Double) -> [MusicEvent] {
        var events: [MusicEvent] = []
        while next < sequences.count, sequences[next].end <= position {
            let music = queue.add(sequences[next], at: now)
            started.append(music)
            events.append(.play(music))
            next += 1
        }
        return events
    }

    /// Advances `terminal` by up to `bytes`, stopping at the end of each sequence so its music starts
    /// at `now`, and stopping early while foreground music holds the drawing.
    public mutating func advance(_ terminal: inout AnsiTerminal, by bytes: Int, at now: Double) -> [MusicEvent] {
        var events = reached(terminal.position, at: now)
        var remaining = bytes
        while remaining > 0, !terminal.isFinished, !queue.isHolding(at: now) {
            var step = remaining
            if let limit, limit > terminal.position { step = min(step, limit - terminal.position) }
            let before = terminal.position
            terminal.advance(byteCount: step)
            remaining -= max(1, terminal.position - before)
            events += reached(terminal.position, at: now)
        }
        return events
    }

    /// The cursor jumped to `position`: audio stops, and music before it counts as played.
    public mutating func seek(to position: Int) -> [MusicEvent] {
        queue.clear()
        started = []
        skip(to: position)
        return [.stop]
    }

    /// Passes music up to `position` without playing it (music off or muted).
    public mutating func skip(to position: Int) {
        next = sequences.firstIndex { $0.end > position } ?? sequences.count
    }

    /// Instant speed: the whole file's music once, from now, never holding the display.
    public mutating func playAll(at now: Double) -> [MusicEvent] {
        queue.clear()
        started = []
        var events: [MusicEvent] = [.stop]
        for sequence in sequences {
            let music = queue.add(sequence, at: now, holds: false)
            started.append(music)
            events.append(.play(music))
        }
        next = sequences.count
        return events
    }

    public mutating func pause(at now: Double) -> [MusicEvent] {
        queue.pause(at: now) ? [.pause] : []
    }

    public mutating func resume(at now: Double) -> [MusicEvent] {
        let wasActive = queue.pausedAt.map { queue.isActive(at: $0) } ?? false
        let delta = queue.resume(at: now)
        for i in started.indices { started[i].start += delta }
        return wasActive ? [.resume] : []
    }

    public mutating func stop() -> [MusicEvent] {
        queue.clear()
        return [.stop]
    }

    /// Scheduled music as one timeline (note times on the scheduler's clock), for export.
    public static func audioNotes(_ scheduled: [ScheduledMusic]) -> [TimedNote] {
        scheduled.flatMap { music in
            music.notes.map { note in
                var shifted = note
                shifted.start += music.start
                return shifted
            }
        }
    }
}

/// The BBS terminal's music: bytes pass through a `MusicStreamFilter` on their way to the screen.
/// Bytes after foreground music wait in the gate until the music ends (SyncTERM); background
/// music never holds them.
public struct TerminalMusicGate {
    public private(set) var filter: MusicStreamFilter
    public private(set) var queue = MusicQueue()
    /// False when music is silenced: sequences are still removed from the screen but neither
    /// sound nor hold.
    public var plays = true
    private var pending: [UInt8] = []

    public init(mode: MusicMode) {
        filter = MusicStreamFilter(mode: mode)
    }

    /// Bytes waiting for foreground music to end.
    public var held: Int { pending.count }

    public func isHolding(at now: Double) -> Bool { queue.isHolding(at: now) }

    /// Takes the bytes due on screen now; returns what the screen may show and the music to start.
    /// Call with no bytes to release what waited once the music has ended.
    public mutating func feed(_ bytes: [UInt8], at now: Double) -> (visual: [UInt8], events: [MusicEvent]) {
        pending += bytes
        var visual: [UInt8] = []
        var events: [MusicEvent] = []
        while !pending.isEmpty, !queue.isHolding(at: now) {
            let chunk = pending
            pending = []
            let before = filter
            let out = filter.feed(chunk)
            guard plays, let blocking = out.finished.first(where: { $0.isTerminated && $0.blocksDisplay }) else {
                visual += out.visual
                if plays { events += start(out.finished, at: now) }
                continue
            }
            // Show and play up to the end of the foreground music; the rest waits for it.
            filter = before
            let cut = blocking.end - before.consumed
            let head = filter.feed(Array(chunk[..<cut]))
            visual += head.visual
            events += start(head.finished, at: now)
            pending = Array(chunk[cut...])
        }
        return (visual, events)
    }

    private mutating func start(_ sequences: [MusicSequence], at now: Double) -> [MusicEvent] {
        sequences.filter(\.isTerminated).map { .play(queue.add($0, at: now)) }
    }

    /// A new session: forgets waiting bytes, parser state and queued music.
    public mutating func reset(mode: MusicMode) -> [MusicEvent] {
        filter = MusicStreamFilter(mode: mode)
        queue.clear()
        pending = []
        return [.stop]
    }
}
