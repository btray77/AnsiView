import AnsiCore
import AVFoundation

/// Plays the synthesized modem sounds for one art window. The engine starts only when a sound
/// is first needed, so windows with Modem Sounds off never touch audio.
final class ModemSoundPlayer: PlaybackSound {
    static let format = AVAudioFormat(standardFormatWithSampleRate: ModemSound.sampleRate, channels: 1)!
    static let handshakeBuffer = buffer(ModemSound.handshake())
    /// Two seconds of line noise, looped while bytes flow.
    static let noiseBuffer = buffer(ModemSound.lineNoise(seconds: 2, seed: 0x1200))

    private var engine: AVAudioEngine?
    private let node = AVAudioPlayerNode()

    deinit {
        node.stop()
        engine?.stop()
    }

    func playbackStateChanged(_ state: PlaybackSoundState) {
        switch state {
        case .connecting: play(Self.handshakeBuffer, loops: false)
        case .streaming: play(Self.noiseBuffer, loops: true)
        case .quiet:
            node.stop()
            engine?.pause()
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, loops: Bool) {
        guard let engine = runningEngine() else { return }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [])
        if engine.isRunning { node.play() }
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
            do { try engine.start() } catch { return nil }
        }
        return engine
    }

    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Writes the handshake to a sound file (used to check the synthesis by ear or by tools).
    static func writeHandshake(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: handshakeBuffer)
    }
}
