import Foundation

public enum Waveform: String, CaseIterable, Codable {
    /// A PC speaker: a hard square wave.
    case square
    /// A gentler tone (sine with a little third harmonic and short fades) for headphones.
    case soft

    public var title: String { self == .square ? "PC Speaker (square)" : "Soft" }
}

/// Renders timed notes to mono Float32 PCM. Deterministic: the same notes always give the same samples.
public struct MusicSynth {
    public var sampleRate = 44100.0
    public var waveform = Waveform.square
    public var amplitude: Float = 0.25
    /// Longest audio rendered, so hostile input cannot exhaust memory (600 s is about 105 MB).
    public var maxSeconds = 600.0

    public init(waveform: Waveform = .square) {
        self.waveform = waveform
    }

    /// Sample index of a time. Boundaries come from absolute times, so long tunes do not drift.
    public func sampleIndex(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    public func render(_ notes: [TimedNote]) -> [Float] {
        let end = min(notes.map(\.end).max() ?? 0, maxSeconds)
        let total = max(0, sampleIndex(end))
        var samples = [Float](repeating: 0, count: total)
        let fade = max(1, Int(0.005 * sampleRate))
        for note in notes where note.frequency > 0 && note.sounding > 0 {
            let first = sampleIndex(note.start)
            let last = min(total, sampleIndex(note.start + note.sounding))
            guard first < last else { continue }
            let count = last - first
            let step = note.frequency / sampleRate
            var phase = 0.0
            for k in 0..<count {
                let value: Float
                switch waveform {
                case .square:
                    value = phase < 0.5 ? amplitude : -amplitude
                case .soft:
                    let angle = 2 * Double.pi * phase
                    let tone = (sin(angle) + 0.2 * sin(3 * angle)) / 1.2
                    let envelope = min(1, Double(k) / Double(fade), Double(count - 1 - k) / Double(fade))
                    value = amplitude * Float(tone * envelope)
                }
                samples[first + k] += value
                phase += step
                if phase >= 1 { phase -= phase.rounded(.down) }
            }
        }
        return samples
    }
}

/// 16 bit PCM mono WAV.
public enum WAVFile {
    public static func data(_ samples: [Float], sampleRate: Int = 44100) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(44 + samples.count * 2)
        func u32(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func u16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        let dataSize = samples.count * 2
        out += Array("RIFF".utf8); u32(36 + dataSize)
        out += Array("WAVEfmt ".utf8); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        out += Array("data".utf8); u32(dataSize)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            u16(Int(UInt16(bitPattern: value)))
        }
        return Data(out)
    }
}

/// Standard MIDI File, type 0: an extra for taking a tune into other software. ANSI music itself
/// is the PLAY string; this is only a translation of its notes.
public enum MIDIFile {
    /// 480 ticks per quarter at 120 BPM: 960 ticks per second, so every PLAY tempo is exact in time.
    public static let ticksPerSecond = 960.0

    public static func data(_ notes: [TimedNote]) -> Data {
        var track: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xC0, 80]
        var now = 0
        func vlq(_ value: Int) -> [UInt8] {
            var value = max(0, value)
            var bytes = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            return bytes
        }
        func tick(_ seconds: Double) -> Int { Int((seconds * ticksPerSecond).rounded()) }
        func event(at time: Int, _ bytes: [UInt8]) {
            let at = max(time, now)
            track += vlq(at - now) + bytes
            now = at
        }
        for note in notes {
            guard let semitone = note.semitone, note.sounding > 0 else { continue }
            let key = UInt8(min(127, semitone + 36))
            let on = tick(note.start)
            event(at: on, [0x90, key, 100])
            event(at: max(on + 1, tick(note.start + note.sounding)), [0x80, key, 0])
        }
        event(at: tick(notes.map(\.end).max() ?? 0), [0xFF, 0x2F, 0x00])
        var out = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        out += Array("MTrk".utf8)
        let length = track.count
        out += [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        return Data(out + track)
    }
}
