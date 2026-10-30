import Foundation

/// The modem sound as a video's sound track (plan 10 ruling 5), on the same timing the viewer
/// uses: the handshake over the empty screen, line noise while bytes arrive, then silence for the
/// final hold. All of it is AnsiView's own synthesis (`ModemSound`), no recording.
public enum ModemSoundTrack {
    /// The rate of the video sound track (`AnsiExporter.audioSampleRate`).
    public static let sampleRate = 44_100

    /// Mono samples at `sampleRate`: the handshake, `drawSeconds` of looped line noise, then
    /// silence up to `totalSeconds` (never shorter than the handshake).
    public static func samples(drawSeconds: Double, totalSeconds: Double) -> [Float] {
        let rate = Double(sampleRate)
        var out = resample(ModemSound.handshake(), from: ModemSound.sampleRate, to: rate)
        // Exactly the handshake's length, so the art starts where the video's frames say.
        let handshakeCount = Int((ModemSound.handshakeSeconds * rate).rounded())
        if out.count > handshakeCount { out.removeLast(out.count - handshakeCount) }
        out += [Float](repeating: 0, count: handshakeCount - out.count)
        let total = max(handshakeCount, Int((totalSeconds * rate).rounded()))
        let noiseCount = min(total - handshakeCount, Int((max(0, drawSeconds) * rate).rounded()))
        if noiseCount > 0 {
            // The same two second loop the viewer plays.
            let loop = resample(ModemSound.lineNoise(seconds: 2, seed: 0x1200), from: ModemSound.sampleRate, to: rate)
            out.reserveCapacity(total)
            for i in 0..<noiseCount { out.append(loop[i % loop.count]) }
        }
        out += [Float](repeating: 0, count: total - out.count)
        return out
    }

    /// Linear interpolation from one sample rate to another.
    public static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard !samples.isEmpty, source > 0, target > 0 else { return [] }
        let count = Int((Double(samples.count) * target / source).rounded())
        let step = source / target
        return (0..<count).map { i in
            let position = Double(i) * step
            let index = Int(position)
            let next = min(samples.count - 1, index + 1)
            let fraction = Float(position - Double(index))
            return samples[min(index, samples.count - 1)] * (1 - fraction) + samples[next] * fraction
        }
    }

    /// Two tracks added together, clamped to -1...1, as long as the longer one.
    public static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { i in
            let sum = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
            return max(-1, min(1, sum))
        }
    }

    /// `samples` starting `seconds` later (silence first).
    public static func delayed(_ samples: [Float], by seconds: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        return [Float](repeating: 0, count: Int((seconds * Double(sampleRate)).rounded())) + samples
    }
}
