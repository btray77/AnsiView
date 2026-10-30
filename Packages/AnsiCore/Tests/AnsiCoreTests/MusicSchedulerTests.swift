import Foundation
import Testing
@testable import AnsiCore

/// The clock injected scheduler behind viewer, terminal and export music playback.
@Suite struct MusicSchedulerTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func file(_ stream: [UInt8]) -> ArtFile { ArtFile(data: Data(stream), fileExtension: "ans") }

    /// 100 bytes of art, a foreground tune of one 0.5 s note, 100 bytes, a background tune of
    /// two 0.5 s notes, 100 bytes.
    private var stream: [UInt8] {
        bytes(String(repeating: "a", count: 100)) + AnsiMusic.escape("T120 L4 MF C")
            + bytes(String(repeating: "b", count: 100)) + AnsiMusic.escape("MB D E")
            + bytes(String(repeating: "c", count: 100))
    }

    private func plays(_ events: [MusicEvent]) -> [ScheduledMusic] {
        events.compactMap { if case .play(let music) = $0 { return music } else { return nil } }
    }

    // MARK: Queue

    @Test func queueSerializesAndHolds() {
        let scan = AnsiMusic.scan(AnsiMusic.escape("MB C D") + AnsiMusic.escape("MF E"))
        var queue = MusicQueue()
        let first = queue.add(scan.sequences[0], at: 0)
        let second = queue.add(scan.sequences[1], at: 0.25)
        #expect(first.start == 0 && first.end == 1)
        #expect(!first.holds)
        #expect(second.start == 1 && second.end == 1.5)
        #expect(second.holds)
        #expect(queue.isHolding(at: 0.5))
        #expect(queue.isHolding(at: 1.49))
        #expect(!queue.isHolding(at: 1.5))
        #expect(queue.playing(at: 0.5) == first)
        #expect(queue.playing(at: 1.2) == second)
        #expect(queue.playing(at: 2) == nil)
        #expect(queue.isActive(at: 1.4))
        #expect(!queue.isActive(at: 1.6))
        // A sequence arriving after the speaker is free starts at once.
        let third = queue.add(scan.sequences[0], at: 5)
        #expect(third.start == 5)
    }

    @Test func backgroundAloneNeverHolds() {
        let scan = AnsiMusic.scan(AnsiMusic.escape("MB C D E"))
        var queue = MusicQueue()
        _ = queue.add(scan.sequences[0], at: 0)
        #expect(!queue.isHolding(at: 0.1))
        #expect(queue.isActive(at: 0.1))
    }

    // MARK: File playback

    @Test func advanceStopsAtSequenceEndAndStartsMusic() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        #expect(scheduler.sequences.count == 2)
        var terminal = AnsiTerminal(source)
        let mf = scheduler.sequences[0]
        let events = scheduler.advance(&terminal, by: 1000, at: 3)
        #expect(terminal.position == mf.end + 1)  // the SI after the 0x0E belongs to the sequence
        let started = plays(events)
        #expect(started.count == 1)
        #expect(started[0].start == 3)
        #expect(started[0].end == 3.5)
        #expect(started[0].holds)
        #expect(scheduler.isHolding(at: 3.2))
    }

    @Test func foregroundBlocksFurtherAdvanceUntilItEnds() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        var terminal = AnsiTerminal(source)
        _ = scheduler.advance(&terminal, by: 1000, at: 0)
        let held = terminal.position
        #expect(scheduler.advance(&terminal, by: 50, at: 0.3).isEmpty)
        #expect(terminal.position == held)
        _ = scheduler.advance(&terminal, by: 50, at: 0.5)
        #expect(terminal.position == held + 50)
    }

    @Test func backgroundPlaysWhileDrawingContinues() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        var terminal = AnsiTerminal(source)
        _ = scheduler.advance(&terminal, by: 1000, at: 0)
        // Background music starts and the same frame's bytes keep drawing past it.
        let events = scheduler.advance(&terminal, by: 1000, at: 1)
        #expect(plays(events).map(\.start) == [1])
        #expect(terminal.isFinished)
        #expect(!scheduler.isHolding(at: 1.1))
        #expect(scheduler.queue.isActive(at: 1.9))
        #expect(scheduler.queue.playing(at: 1.9)?.holds == false)
    }

    @Test func seekStopsAndTreatsPassedMusicAsPlayed() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        var terminal = AnsiTerminal(source)
        _ = scheduler.advance(&terminal, by: 1000, at: 0)
        let events = scheduler.seek(to: scheduler.sequences[0].end + 10)
        #expect(events == [.stop])
        #expect(scheduler.next == 1)
        #expect(!scheduler.isHolding(at: 0.1))
        #expect(!scheduler.queue.isActive(at: 0.1))
        _ = scheduler.seek(to: 0)
        #expect(scheduler.next == 0)
        terminal.seek(to: 0)
        #expect(plays(scheduler.advance(&terminal, by: 1000, at: 2)).map(\.start) == [2])
    }

    @Test func speedChangeDoesNotMoveMusicTiming() {
        // Small and large byte steps reach the sequence on the same frame time: same music.
        func run(step: Int) -> [ScheduledMusic] {
            let source = file(stream)
            var scheduler = MusicPlaybackScheduler(file: source)
            var terminal = AnsiTerminal(source)
            var all: [ScheduledMusic] = []
            var time = 0.0
            while !terminal.isFinished {
                all += plays(scheduler.advance(&terminal, by: step, at: time))
                time += 0.1
            }
            return all
        }
        let slow = run(step: 30), fast = run(step: 300)
        #expect(slow.count == 2 && fast.count == 2)
        // The hold is in seconds: 0.5 s whatever the speed.
        #expect(slow[0].end - slow[0].start == 0.5)
        #expect(fast[0].end - fast[0].start == 0.5)
        // Fast reaches the first tune on the first frame; slow after four frames of 30 bytes.
        #expect(fast[0].start == 0)
        #expect(abs(slow[0].start - 0.3) < 1e-9)
    }

    @Test func pauseShiftsEveryTime() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        var terminal = AnsiTerminal(source)
        _ = scheduler.advance(&terminal, by: 1000, at: 0)
        #expect(scheduler.pause(at: 0.2) == [.pause])
        #expect(scheduler.isHolding(at: 5))
        #expect(scheduler.resume(at: 10.2) == [.resume])
        #expect(scheduler.isHolding(at: 10.4))
        #expect(!scheduler.isHolding(at: 10.5))
        #expect(scheduler.started[0].start == 10)
        // Pausing with nothing playing says nothing to the output.
        #expect(scheduler.pause(at: 20) == [])
        #expect(scheduler.resume(at: 21) == [])
    }

    @Test func playAllQueuesEverythingWithoutHolding() {
        var scheduler = MusicPlaybackScheduler(file: file(stream))
        let started = plays(scheduler.playAll(at: 4))
        #expect(started.map(\.start) == [4, 4.5])
        #expect(started.allSatisfy { !$0.holds })
        #expect(!scheduler.isHolding(at: 4.1))
        #expect(scheduler.limit == nil)
        #expect(scheduler.queue.isActive(at: 5.4))
    }

    @Test func skipIsSilent() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        var terminal = AnsiTerminal(source)
        terminal.advance(byteCount: 150)  // past the first tune, before the second
        scheduler.skip(to: terminal.position)
        #expect(scheduler.next == 1)
        #expect(!scheduler.isHolding(at: 0))
        #expect(scheduler.started.isEmpty)
    }

    @Test func stopClearsTheQueue() {
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        var terminal = AnsiTerminal(source)
        _ = scheduler.advance(&terminal, by: 1000, at: 0)
        #expect(scheduler.stop() == [.stop])
        #expect(!scheduler.isHolding(at: 0.1))
        #expect(scheduler.next == 1)
    }

    @Test func audioNotesShiftByStart() {
        let scan = AnsiMusic.scan(AnsiMusic.escape("C") + AnsiMusic.escape("D"))
        var queue = MusicQueue()
        let a = queue.add(scan.sequences[0], at: 1)
        let b = queue.add(scan.sequences[1], at: 3)
        let notes = MusicPlaybackScheduler.audioNotes([a, b])
        #expect(notes.map(\.start) == [1, 3])
        #expect(notes.map(\.semitone) == [48, 50])
    }

    @Test func fileWithoutMusicHasNoLimit() {
        let source = file(bytes("plain art\r\n"))
        var scheduler = MusicPlaybackScheduler(file: source)
        #expect(!scheduler.hasMusic)
        #expect(scheduler.limit == nil)
        var terminal = AnsiTerminal(source)
        #expect(scheduler.advance(&terminal, by: 4, at: 0).isEmpty)
        #expect(terminal.position == 4)
    }

    @Test func unterminatedMusicIsNotScheduled() {
        let source = file(bytes("x") + [0x1B] + bytes("[MC D\r\nart"))
        #expect(!MusicPlaybackScheduler(file: source).hasMusic)
    }

    @Test func sequenceEndsAreTerminalPositions() {
        // With CTSAM, SI after music and plain escapes mixed in, stopping at each limit lands
        // exactly on the sequence end (or one past it for the SI).
        let esc: UInt8 = 0x1B
        let stream = bytes("A") + [esc] + bytes("[1;31mB") + AnsiMusic.escape("C", introducer: .n, shiftIn: false)
            + [esc] + bytes("[=0M") + AnsiMusic.escape("D", introducer: .pipe) + bytes("C")
            + AnsiMusic.escape("E", introducer: .m) + bytes("D")
        let source = file(stream)
        var scheduler = MusicPlaybackScheduler(file: source)
        // ESC[=0M leaves only ESC[| as music, so the last ESC[M is Delete Line, not music.
        #expect(scheduler.sequences.count == 2)
        var terminal = AnsiTerminal(source)
        var ends: [Int] = []
        var time = 0.0
        while !terminal.isFinished {
            let before = scheduler.next
            _ = scheduler.advance(&terminal, by: 1, at: time)
            if scheduler.next != before { ends.append(terminal.position) }
            time += 10
        }
        #expect(ends == [scheduler.sequences[0].end, scheduler.sequences[1].end + 1])
    }

    // MARK: Terminal gate

    private func run(_ gate: inout TerminalMusicGate, chunks: [[UInt8]], step: Double = 0.05, until end: Double = 20)
        -> (visual: [(time: Double, bytes: [UInt8])], plays: [ScheduledMusic]) {
        var visual: [(Double, [UInt8])] = []
        var started: [ScheduledMusic] = []
        var queue = chunks
        var time = 0.0
        while time <= end {
            let next = queue.isEmpty ? [] : queue.removeFirst()
            let out = gate.feed(next, at: time)
            if !out.visual.isEmpty { visual.append((time, out.visual)) }
            started += plays(out.events)
            time += step
        }
        return (visual, started)
    }

    @Test func gateHoldsBytesAfterForegroundMusic() {
        var gate = TerminalMusicGate(mode: .all)
        let out = gate.feed(stream, at: 0)
        // Up to and including the first tune; the rest waits.
        #expect(out.visual == bytes(String(repeating: "a", count: 100)))
        #expect(plays(out.events).count == 1)
        #expect(gate.isHolding(at: 0.4))
        #expect(gate.held > 0)
        #expect(gate.feed([], at: 0.4).visual.isEmpty)
        let after = gate.feed([], at: 0.5)
        #expect(after.visual == bytes(String(repeating: "b", count: 100) + String(repeating: "c", count: 100)))
        #expect(plays(after.events).map(\.start) == [0.5])
        #expect(!gate.isHolding(at: 0.6))
        #expect(gate.held == 0)
    }

    @Test func gateIsTheSameForEverySplit() {
        var whole = TerminalMusicGate(mode: .all)
        let reference = run(&whole, chunks: [stream])
        let referenceText = reference.visual.flatMap(\.bytes)
        #expect(referenceText == AnsiMusic.scan(stream).visual)
        for split in stride(from: 1, to: stream.count, by: 7) {
            var gate = TerminalMusicGate(mode: .all)
            let result = run(&gate, chunks: [Array(stream[..<split]), Array(stream[split...])])
            #expect(result.visual.flatMap(\.bytes) == referenceText)
            #expect(result.plays.map(\.sequence.body) == reference.plays.map(\.sequence.body))
            // Nothing after the foreground tune is shown before it ends.
            let firstPlay = result.plays[0]
            let bIndex = result.visual.first { $0.bytes.contains(UInt8(ascii: "b")) }
            #expect(bIndex.map { $0.time >= firstPlay.end - 1e-9 } == true)
        }
    }

    @Test func gateBackgroundDoesNotHold() {
        var gate = TerminalMusicGate(mode: .bananaCom)
        let out = gate.feed(bytes("x") + AnsiMusic.escape("MB C D E", introducer: .n) + bytes("y"), at: 0)
        #expect(out.visual == bytes("xy"))
        #expect(plays(out.events).count == 1)
        #expect(!gate.isHolding(at: 0.1))
    }

    @Test func gateModeOffPassesEverything() {
        let input = bytes("x") + AnsiMusic.escape("C", introducer: .pipe) + bytes("y")
        var gate = TerminalMusicGate(mode: .off)
        let out = gate.feed(input, at: 0)
        #expect(out.visual == input)
        #expect(out.events.isEmpty)
    }

    @Test func gateHonoursCTSAM() {
        var gate = TerminalMusicGate(mode: .bananaCom)
        let esc: UInt8 = 0x1B
        let out = gate.feed([esc] + bytes("[=2M") + AnsiMusic.escape("MB C", introducer: .m), at: 0)
        #expect(out.visual == [esc] + bytes("[=2M"))
        #expect(plays(out.events).count == 1)
        // Default BANSI: ESC[M is Delete Line, passed to the emulator.
        var plain = TerminalMusicGate(mode: .bananaCom)
        #expect(plain.feed(AnsiMusic.escape("MB C", introducer: .m, shiftIn: false), at: 0).events.isEmpty)
    }

    @Test func gateNotPlayingStillRemovesMusic() {
        var gate = TerminalMusicGate(mode: .all)
        _ = gate.setPlays(false, at: 0)
        let out = gate.feed(stream, at: 0)
        #expect(out.events.isEmpty)
        #expect(out.visual == AnsiMusic.scan(stream).visual)
        #expect(!gate.isHolding(at: 0))
    }

    @Test func gateResetStopsAndForgets() {
        var gate = TerminalMusicGate(mode: .all)
        _ = gate.feed(stream, at: 0)
        #expect(gate.reset(mode: .pipe) == [.stop])
        #expect(gate.held == 0)
        #expect(!gate.isHolding(at: 0.1))
        #expect(gate.feed(AnsiMusic.escape("C", introducer: .m, shiftIn: false), at: 1).events.isEmpty)
    }

    @Test func gateFuzzMatchesScan() {
        var generator = SeededGenerator(seed: 77)
        let alphabet: [UInt8] = [0x1B, 0x5B, 0x4D, 0x4E, 0x7C, 0x0E, 0x0F, 0x3D, 0x32, 0x43, 0x44, 0x20, 0x4D, 0x46, 0x42, 0x0D, 0x0A, 0x41]
        for _ in 0..<300 {
            let length = Int.random(in: 0...120, using: &generator)
            let input = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }
            var chunks: [[UInt8]] = []
            var rest = input[...]
            while !rest.isEmpty {
                let take = Int.random(in: 1...max(1, rest.count), using: &generator)
                chunks.append(Array(rest.prefix(take)))
                rest = rest.dropFirst(take)
            }
            var gate = TerminalMusicGate(mode: .all)
            let result = run(&gate, chunks: chunks, step: 0.5, until: 400)
            var filter = MusicStreamFilter(mode: .all)
            let expected = filter.feed(input).visual
            #expect(result.visual.flatMap(\.bytes) == expected)
        }
    }
}

/// Findings from the final review of the playback branch.
@Suite struct MusicPlaybackReviewTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func plays(_ events: [MusicEvent]) -> [ScheduledMusic] {
        events.compactMap { if case .play(let music) = $0 { return music } else { return nil } }
    }

    @Test func gateTurningOffReleasesHold() {
        var gate = TerminalMusicGate(mode: .all)
        _ = gate.feed(AnsiMusic.escape("MF C D E") + bytes("after"), at: 0)
        #expect(gate.isHolding(at: 0.1))
        #expect(gate.setPlays(false, at: 0.1) == [.stop])
        #expect(!gate.isHolding(at: 0.1))
        #expect(gate.feed([], at: 0.1).visual == bytes("after"))
        // Turning it on again says nothing to the output.
        #expect(gate.setPlays(true, at: 0.2) == [])
    }

    @Test func hostileTuneHoldIsCapped() {
        let tune = "T32 L1 MF " + String(repeating: "P1 ", count: 3000)
        var scheduler = MusicPlaybackScheduler(AnsiMusic.scan(AnsiMusic.escape(tune)).sequences)
        let started = plays(scheduler.reached(Int.max, at: 0))
        #expect(started.count == 1)
        #expect(started[0].end <= MusicPlaybackScheduler.maxTuneSeconds)
        #expect(!scheduler.isHolding(at: MusicPlaybackScheduler.maxTuneSeconds + 0.001))
    }

    @Test func playAllStopsQueueingPastTheCap() {
        let long = AnsiMusic.escape("T32 L1 MB " + String(repeating: "C ", count: 100))  // 750 s, capped to 600
        var scheduler = MusicPlaybackScheduler(AnsiMusic.scan(long + long + long).sequences)
        let started = plays(scheduler.playAll(at: 0))
        #expect(started.count == 1)
        #expect(started.map(\.end).max()! <= MusicPlaybackScheduler.maxTuneSeconds)
    }

    @Test func exportAudioKeepsTunesLateInLongVideos() {
        let scan = AnsiMusic.scan(AnsiMusic.escape("MF C"))
        var queue = MusicQueue()
        let late = queue.add(scan.sequences[0], at: 700)
        let samples = MusicPlaybackScheduler.audioSamples([late], length: 701)
        #expect(samples.count == Int((701 * 44100.0).rounded()))
        let window = samples[(700 * 44100)..<(700 * 44100 + 4410)]
        #expect(window.contains { $0 != 0 })
        #expect(samples[0..<(699 * 44100)].allSatisfy { $0 == 0 })
        // The total is bounded.
        #expect(MusicPlaybackScheduler.audioSamples([late], length: 1e9).count
                == Int(MusicPlaybackScheduler.maxExportSeconds * 44100))
    }

    @Test func pauseWithNothingPlayingLeavesNoPause() {
        var queue = MusicQueue()
        let paused = queue.pause(at: 1)
        #expect(!paused)
        #expect(queue.pausedAt == nil)
    }
}
