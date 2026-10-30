import AnsiCore
import AVFoundation

/// Plays rendered ANSI music through AVAudioEngine with play, pause and stop.
/// The engine starts only when something plays.
final class MusicAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var attached = false
    /// Bumped on every play and stop so a finished callback from older audio is ignored.
    private var generation = 0
    private(set) var isPaused = false
    private(set) var duration = 0.0
    private var pausedTime = 0.0

    /// Called on the main queue when the music plays to its end.
    var onFinish: (() -> Void)?

    var isPlaying: Bool { node.isPlaying && !isPaused }
    var isActive: Bool { node.isPlaying || isPaused }

    /// Seconds played since `play` (frozen while paused).
    var currentTime: Double {
        if isPaused { return pausedTime }
        guard let renderTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: renderTime) else { return 0 }
        return max(0, min(duration, Double(playerTime.sampleTime) / playerTime.sampleRate))
    }

    func play(_ notes: [TimedNote], waveform: Waveform) {
        stop()
        let samples = MusicSynth(waveform: waveform).render(notes)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("AnsiView music: audio engine did not start: \(error.localizedDescription)")
            return
        }
        duration = Double(samples.count) / 44100
        generation += 1
        let current = generation
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                // Stop the node so isPlaying is false once the audio has ended.
                self.node.stop()
                self.isPaused = false
                self.onFinish?()
            }
        }
        isPaused = false
        node.play()
    }

    func pause() {
        guard node.isPlaying else { return }
        pausedTime = currentTime
        node.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        node.play()
    }

    func stop() {
        generation += 1
        isPaused = false
        if attached { node.stop() }
    }
}
