import AnsiCore
import AppKit
import AVFoundation

/// Plays a window's ANSI music on one AVAudioPlayerNode: each tune is rendered with the square
/// wave (PC speaker) synth and queued after the previous one, the way one speaker played them.
/// The engine starts with the first tune and stops when the queue is empty or stopped.
final class AudioMusicOutput: MusicOutput {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    private var engine: AVAudioEngine?
    private let node = AVAudioPlayerNode()
    /// Tunes queued and not yet played back.
    private var queued = 0
    /// Bumped on stop so completion callbacks from older tunes are ignored.
    private var generation = 0
    private var paused = false

    deinit {
        node.stop()
        engine?.stop()
    }

    func enqueue(_ notes: [TimedNote]) {
        let samples = MusicSynth(waveform: .square).render(notes)
        guard !samples.isEmpty, let engine = runningEngine(),
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        queued += 1
        let current = generation
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.queued -= 1
                if self.queued <= 0 { self.stop() }
            }
        }
        if engine.isRunning, !paused, !node.isPlaying { node.play() }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        node.pause()
    }

    func resume() {
        guard paused else { return }
        paused = false
        if queued > 0 { node.play() }
    }

    func stop() {
        generation += 1
        queued = 0
        paused = false
        node.stop()
        engine?.stop()  // releases the audio hardware until the next tune
    }

    private func runningEngine() -> AVAudioEngine? {
        if engine == nil {
            let engine = AVAudioEngine()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: Self.format)
            self.engine = engine
        }
        guard let engine else { return nil }
        if !engine.isRunning {
            do { try engine.start() } catch {
                NSLog("AnsiView music: audio engine did not start: \(error.localizedDescription)")
                return nil
            }
        }
        return engine
    }
}

/// The (?) explanation of ANSI music: Playback > About ANSI Music and the export panel.
enum MusicPlaybackHelp {
    static let about = """
        ANSI music is sound sent inside ANSI art and BBS screens: a BASIC PLAY tune (notes, octaves, \
        lengths, tempo) after ESC[M, ESC[N or ESC[| and ended by Ctrl-N. Qmodem, Telix, TeleMate and \
        SyncTERM played it through the PC speaker.

        Foreground music (MF, the default) pauses the drawing until the tune has finished. Background \
        music (MB) plays while the art keeps drawing.

        Viewer: music plays when playback reaches it, at any speed. At Instant speed the file's music \
        plays once from the start (Playback > Play Music at Instant Speed). Click the \u{266A} badge or choose \
        Playback > Mute Music in This Window to silence one window; Playback > Play ANSI Music turns it \
        off everywhere. Quick Look previews never play sound.

        Terminal: each dialing directory entry chooses which codes play: Off, ESC[| only, BANSI \
        (ESC[| and ESC[N, SyncTERM's default) or All (also ESC[M, which is then no longer Delete Line). \
        A BBS can switch with ESC[=0M, ESC[=1M or ESC[=2M unless the entry says Off.

        Export: MP4 video can carry the music as a sound track. GIF and WebP have no sound.
        """

    static let export = "Adds the file's ANSI music to the MP4 as a sound track, timed with the frames: "
        + "foreground music (MF) holds the picture until it ends, as in the viewer. GIF and WebP have no sound."

    @MainActor
    static func showAbout() {
        let alert = NSAlert()
        alert.messageText = "About ANSI Music"
        alert.informativeText = about
        alert.runModal()
    }
}
