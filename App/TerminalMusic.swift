import AnsiCore
import Foundation

/// ANSI music for a terminal window: the bytes released for the screen pass through a
/// `TerminalMusicGate`, music plays as it arrives, and bytes after foreground music wait until it
/// ends (SyncTERM). Playback > Play ANSI Music off silences it; the music bytes are still kept off
/// the screen according to the entry's mode.
final class TerminalMusic {
    private(set) var gate: TerminalMusicGate
    /// Where the tunes play (a harness may record instead).
    var output: MusicOutput?
    /// The clock tunes are timed by (a harness may replace it).
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Every tune started, with its clock times (for the window and harnesses).
    private(set) var started: [ScheduledMusic] = []

    init(mode: MusicMode, output: MusicOutput? = AudioMusicOutput()) {
        gate = TerminalMusicGate(mode: mode)
        self.output = output
    }

    deinit { output?.stop() }

    /// True during a file transfer: no music plays or holds (a playing tune stops).
    private(set) var suspended = false

    /// A file transfer starts: music stops; returns the bytes `bytes` and any bytes that waited
    /// for foreground music, for the screen at once.
    func suspend(drawing bytes: [UInt8]) -> [UInt8] {
        suspended = true
        return screenBytes(bytes)
    }

    /// The transfer ended: music plays again from the next tune that arrives.
    func resumeAfterTransfer() { suspended = false }

    /// True while foreground music holds the screen (the line pacer should not release more).
    var isHolding: Bool { gate.isHolding(at: clock()) }

    /// The bytes due on screen (empty to release what waited); returns what the emulator may show.
    func screenBytes(_ bytes: [UInt8]) -> [UInt8] {
        for event in gate.setPlays(PlaybackSpeed.ansiMusic && output != nil && !suspended, at: clock()) { perform(event) }
        let out = gate.feed(bytes, at: clock())
        for event in out.events { perform(event) }
        return out.visual
    }

    /// A new session (connect or reconnect): music and waiting bytes from the old one are dropped.
    func reset(mode: MusicMode) {
        for event in gate.reset(mode: mode) { perform(event) }
        started = []
    }

    private func perform(_ event: MusicEvent) {
        switch event {
        case .play(let music):
            started.append(music)
            if started.count > 1000 { started.removeFirst(started.count - 1000) }
            output?.enqueue(music.notes)
        case .pause: output?.pause()
        case .resume: output?.resume()
        case .stop: output?.stop()
        }
    }
}
